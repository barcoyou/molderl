
-module(molderl_stream).

-behaviour(gen_server).

-export([start_link/7, send/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("molderl.hrl").

-compile([{parse_transform, lager_transform}]).

-define(STATE,State#state).

-record(state, {stream_name :: binary(),                 % Name of the stream encoded for MOLD64 (i.e. padded binary)
                destination :: inet:ip4_address(),       % The IP address to send / broadcast / multicast to
                sequence_number = 1 :: pos_integer(),    % Next sequence number
                socket :: inet:socket(),                 % The socket to send the data on
                destination_port :: inet:port_number(),  % Destination port for the data
                messages = [] :: [binary()],             % List of messages waiting to be encoded and sent
                message_length = 0 :: non_neg_integer(), % Current length of messages if they were to be encoded in a MOLD64 packet
                recovery_service :: pid() ,              % Pid of the recovery service message
                start_time :: erlang:timestamp(),        % Start time of the earliest msg in a packet
                prod_interval :: pos_integer(),          % Maximum interval at which either partial packets or heartbeats should be sent
                timer_ref :: reference(),                % reference to timer used for hearbeats and flush interval
                statsd_latency_key_in :: string(),       % cache the StatsD key to prevent binary_to_list/1 calls and concatenation all the time
                statsd_latency_key_out :: string(),      % cache the StatsD key to prevent binary_to_list/1 calls and concatenation all the time
                statsd_count_key :: string()             % cache the StatsD key to prevent binary_to_list/1 calls and concatenation all the time
               }).

start_link(SupervisorPid, StreamName, Destination, DestinationPort,
           RecoveryPort, IPAddressToSendFrom, Timer) ->
    gen_server:start_link(?MODULE,
                          [SupervisorPid, StreamName, Destination, DestinationPort,
                           RecoveryPort, IPAddressToSendFrom, Timer],
                          []).

-spec send(pid(), binary(), erlang:timestamp()) -> 'ok'.
send(Pid, Message, StartTime) ->
    gen_server:cast(Pid, {send, Message, StartTime}).

init([SupervisorPID, StreamName, Destination, DestinationPort,
      RecoveryPort, IPAddressToSendFrom, ProdInterval]) ->

    MoldStreamName = molderl_utils:gen_streamname(StreamName),

    % send yourself a reminder to start recovery process
    self() ! {initialize, SupervisorPID, StreamName, RecoveryPort, ?PACKET_SIZE},

    Connection = gen_udp:open(0, [binary,
                                    {broadcast, true},
                                    {ip, IPAddressToSendFrom},
                                    {add_membership, {Destination, IPAddressToSendFrom}},
                                    {multicast_if, IPAddressToSendFrom}]),

    case Connection of
        {ok, Socket} ->
            State = #state{stream_name = MoldStreamName,
                           destination = Destination,
                           socket = Socket,
                           destination_port = DestinationPort,
                           timer_ref = erlang:send_after(ProdInterval, self(), prod),
                           prod_interval = ProdInterval,
                           statsd_latency_key_in = "molderl." ++ atom_to_list(StreamName) ++ ".time_in",
                           statsd_latency_key_out = "molderl." ++ atom_to_list(StreamName) ++ ".time_out",
                           statsd_count_key = "molderl." ++ atom_to_list(StreamName) ++ ".sent"
                          },
            {ok, State};
        {error, Reason} ->
            lager:error("[molderl] Unable to open UDP socket on ~p because '~p'. Aborting.",
                      [IPAddressToSendFrom, inet:format_error(Reason)]),
            {stop, Reason}
    end.

handle_cast({send, Message, StartTime}, State=#state{messages=[]}) -> % first msg on the queue
    statsderl:timing_now(?STATE.statsd_latency_key_in, StartTime, 0.1),
    MessageLength = molderl_utils:message_length(0, Message),
    % first, check if single message is bigger than packet size
    case MessageLength > ?PACKET_SIZE of
        true -> % log error, ignore message, but continue
            lager:error("Molderl received a single message of length ~p"
                        ++ " which is bigger than the maximum packet size ~p",
                        [MessageLength, ?PACKET_SIZE]),
            {noreply, State};
        false ->
            {noreply, ?STATE{message_length=MessageLength, messages=[Message], start_time=StartTime}}
    end;
handle_cast({send, Message, StartTime}, State) ->
    % Can we fit this in?
    MessageLength = molderl_utils:message_length(?STATE.message_length, Message),
    case MessageLength > ?PACKET_SIZE of
        true -> % Nope we can't, send what we have and requeue
            erlang:cancel_timer(?STATE.timer_ref),
            NewState = flush(State),
            molderl_stream:send(self(), Message, StartTime), % requeue latest msg since it didn't fit
            {noreply, NewState};
        false -> % Yes we can - add it to the list of messages
            {noreply, ?STATE{message_length=MessageLength, messages=[Message|?STATE.messages]}}
    end.

handle_info({initialize, SupervisorPID, StreamName, RecoveryPort, PacketSize}, State) ->
    RecoverySpec = ?CHILD(make_ref(), molderl_recovery, [StreamName, RecoveryPort, PacketSize], transient, worker),
    {ok, RecoveryProcess} = supervisor:start_child(SupervisorPID, RecoverySpec),
    {noreply, ?STATE{recovery_service=RecoveryProcess}};
handle_info(prod, State=#state{messages=[]}) -> % Timer triggered a send, but msg queue empty
    ok = send_heartbeat(State),
    TRef = erlang:send_after(?STATE.prod_interval, self(), prod),
    {noreply, ?STATE{message_length=0, messages=[], timer_ref=TRef}};
handle_info(prod, State) -> % Timer triggered a send
    lager:debug("[molderl] stream ~p: forced partial packet send due to timeout", [?STATE.stream_name]),
    NewState = flush(State),
    {noreply, NewState}.

handle_call(Msg, _From, State) ->
    lager:warning("[molderl] Unexpected message in module ~p: ~p",[?MODULE, Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, State) ->
    Fmt = "[molderl] molderl_stream process for stream ~p is exiting because of reason ~p.",
    lager:error(Fmt, [string:strip(binary_to_list(State#state.stream_name)), Reason]),
    ok.

-spec flush(#state{}) -> #state{}.
flush(State) -> % send out the messages in the current buffer queue
    EncodedMsgs = molderl_utils:encode_messages(?STATE.messages),
    {Count, Payload} = molderl_utils:gen_messagepacket(?STATE.stream_name, ?STATE.sequence_number, lists:reverse(EncodedMsgs)),
    ok = gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, Payload),
    statsderl:timing_now(?STATE.statsd_latency_key_out, ?STATE.start_time, 0.1),
    statsderl:increment(?STATE.statsd_count_key, 1, 0.1),

    molderl_recovery:store(?STATE.recovery_service, EncodedMsgs),

    TRef = erlang:send_after(?STATE.prod_interval, self(), prod),
    ?STATE{message_length=0, messages=[], sequence_number=?STATE.sequence_number+Count, timer_ref=TRef}.

-spec send_heartbeat(#state{}) -> 'ok' | {'error', inet:posix() | 'not_owner'}.
send_heartbeat(State) ->
    Heartbeat = molderl_utils:gen_heartbeat(?STATE.stream_name, ?STATE.sequence_number),
    gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, Heartbeat).

%send_endofsession(State) ->
%    EndOfSession = molderl_utils:gen_endofsession(?STATE.stream_name, ?STATE.sequence_number),
%    gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, EndOfSession).

