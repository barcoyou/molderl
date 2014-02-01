
-module(molderl_stream_sup).

-behaviour(supervisor).

%% API
-export([start_link/6]).

%% Supervisor callbacks
-export([init/1]).

-include("molderl.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link(StreamName, Destination, DestinationPort,
           RecoveryPort, IPAddressToSendFrom, Timer) ->
    supervisor:start_link(?MODULE, [StreamName, Destination, DestinationPort,
                                    RecoveryPort, IPAddressToSendFrom, Timer]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(Args) ->
    Stream = ?CHILD(make_ref(), molderl_stream, [self()|Args], transient, worker),
    {ok, {{one_for_all, 5, 10}, [Stream]}}.
