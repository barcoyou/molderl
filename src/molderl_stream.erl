
-module(molderl_stream).

-behaviour(gen_server).

-export([start_link/7, prod/1, send/2, send/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("molderl.hrl").

-compile([{parse_transform, lager_transform}]).

-define(STATE,State#state).

-record(state, { stream_name,           % Name of the stream encoded for MOLD64 (i.e. padded binary)
                 destination,           % The IP address to send / broadcast / multicast to
                 sequence_number = 1,   % Next sequence number
                 socket,                % The socket to send the data on
                 destination_port,      % Destination port for the data
                 messages = [],         % List of messages waiting to be encoded and sent
                 message_length = 0,    % Current length of messages if they were to be encoded in a MOLD64 packet
                 recovery_service,      % Pid of the recovery service message
                 start_time,            % Start time of the earliest msg in a packet
                 statsd_latency_key,    % cache the StatsD key to prevent binary_to_list/1 calls and concatenation all the time
                 statsd_count_key       % cache the StatsD key to prevent binary_to_list/1 calls and concatenation all the time
               }).

start_link(SupervisorPid, StreamName, Destination, DestinationPort,
           RecoveryPort, IPAddressToSendFrom, Timer) ->
    gen_server:start_link({local, StreamName},
                          ?MODULE,
                          [SupervisorPid, StreamName, Destination, DestinationPort,
                           RecoveryPort, IPAddressToSendFrom, Timer],
                          []).

send(Pid, Message) ->
    gen_server:cast(Pid, {send, Message, os:timestamp()}).

send(Pid, Message, StartTime) ->
    gen_server:cast(Pid, {send, Message, StartTime}).

prod(Pid) ->
    gen_server:cast(Pid, prod).

init([SupervisorPID, StreamName, Destination, DestinationPort,
      RecoveryPort, IPAddressToSendFrom, ProdInterval]) ->

    MoldStreamName = molderl_utils:gen_streamname(StreamName),

    % send yourself a reminder to start recovery & prodder
    self() ! {initialize, SupervisorPID, StreamName, RecoveryPort, ?PACKET_SIZE, ProdInterval},

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
                           statsd_latency_key = "molderl." ++ atom_to_list(StreamName) ++ ".packet.latency",
                           statsd_count_key   = "molderl." ++ atom_to_list(StreamName) ++ ".packet.sent"
                          },
            {ok, State};
        {error, Reason} ->
            lager:error("Unable to open UDP socket on ~p because ~p. Aborting.~n",
                      [IPAddressToSendFrom, inet:format_error(Reason)]),
            {stop, Reason}
    end.

handle_cast({send, Message, StartTime}, State=#state{messages=[]}) ->
    MessageLength = molderl_utils:message_length(0, Message),
    case MessageLength > ?PACKET_SIZE of
        true -> % Single message is bigger than packet size, log and exit!
            lager:error("Molderl received a single message of length ~p"
                        ++ " which is bigger than the maximum packet size ~p",
                        [MessageLength, ?PACKET_SIZE]),
            {stop, single_msg_too_big, State};
        false ->
            {noreply, ?STATE{message_length=MessageLength, messages=[Message], start_time=StartTime}}
    end;
handle_cast({send, Message, _StartTime}, State) ->
    % Can we fit this in?
    MessageLength = molderl_utils:message_length(?STATE.message_length, Message),
    case MessageLength > ?PACKET_SIZE of
        true -> % Nope we can't, send what we have and requeue
            {NextSequence, MessagesWithSequenceNumbers} = send_packet(State),
            molderl_recovery:store(?STATE.recovery_service, MessagesWithSequenceNumbers),
            {noreply, ?STATE{message_length=molderl_utils:message_length(0,Message),
                             messages=[Message],
                             sequence_number=NextSequence}};
        false -> % Yes we can - add it to the list of messages
            {noreply, ?STATE{message_length=MessageLength, messages=[Message|?STATE.messages]}}
    end;
handle_cast(prod, State) -> % Timer triggered a send
    case ?STATE.messages of
        [] ->
            send_heartbeat(State),
            {noreply, ?STATE{message_length=0, messages=[]}};
        _ ->
            {NextSequence, MessagesWithSequenceNumbers} = send_packet(State),
            molderl_recovery:store(?STATE.recovery_service, MessagesWithSequenceNumbers),
            {noreply, ?STATE{message_length = 0, messages = [], sequence_number = NextSequence}}
    end.

handle_info({initialize, SupervisorPID, StreamName, RecoveryPort, PacketSize, ProdInterval}, State) ->
    ProdderSpec = ?CHILD(make_ref(), molderl_prodder, [self(), ProdInterval], transient, worker),
    supervisor:start_child(SupervisorPID, ProdderSpec),
    RecoverySpec = ?CHILD(make_ref(), molderl_recovery, [StreamName, RecoveryPort, PacketSize], transient, worker),
    {ok, RecoveryProcess} = supervisor:start_child(SupervisorPID, RecoverySpec),
    {noreply, ?STATE{recovery_service=RecoveryProcess}}.

handle_call(Msg, _From, State) ->
    lager:warning("Unexpected message in module ~p: ~p~n",[?MODULE, Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, _State) ->
    ok.

send_packet(State) ->
    MsgPkt = molderl_utils:gen_messagepacket(?STATE.stream_name, ?STATE.sequence_number, lists:reverse(?STATE.messages)),
    {NextSequence, EncodedMessage, MessagesWithSequenceNumbers} = MsgPkt,
    ok = gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, EncodedMessage),
    statsderl:timing_now(?STATE.statsd_latency_key, ?STATE.start_time, 0.01),
    statsderl:increment(?STATE.statsd_count_key, 1, 0.01),
    {NextSequence, MessagesWithSequenceNumbers}.

send_heartbeat(State) ->
    Heartbeat = molderl_utils:gen_heartbeat(?STATE.stream_name, ?STATE.sequence_number),
    gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, Heartbeat).

%send_endofsession(State) ->
%    EndOfSession = molderl_utils:gen_endofsession(?STATE.stream_name, ?STATE.sequence_number),
%    gen_udp:send(?STATE.socket, ?STATE.destination, ?STATE.destination_port, EndOfSession).

