%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkrpc9_client).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_link/2, get_sup_spec/2]).
-export([stop/1, update/2]).
-export([send_request/3, send_async_request/3, reply/2, reply/3, send_event/3]).
-export([call/2, call/3, cast/2]).
-export_type([request/0, reply/0, async_reply/0, event/0]).

-include("nkrpc9.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkserver:id().

-type config() :: map().

-type request() ::
    #{
        srv => nkserver:id(),
        session_id => binary(),
        session_pid => pid(),
        local => binary(),
        remote => binary(),
        tid => nkrpc9_server_protocol:tid(),
        cmd => binary(),
        data => map(),
        user_id => binary(),
        timeout_pending => boolean(),
        debug => boolean()
    }.

-type reply() :: map().


-type async_reply() ::
    {login, UserId::binary(), reply(), request()} |
    {ok, reply(), request()} |
    {error, nkserver_msg:msg(), request()} |
    {ack, pid()|undefined, request()}.


-type event() :: map().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new nkrpc9_http service
-spec start_link(id(), config()) ->
    {ok, pid()} | {error, term()}.

start_link(Id, Config) ->
    nkserver:start_link(?PACKAGE_CLASS_RPC9_CLIENT, Id, Config).


%% @doc Retrieves a service as a supervisor child specification
-spec get_sup_spec(id(), config()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_sup_spec(Id, Config) ->
    nkserver:get_sup_spec(?PACKAGE_CLASS_RPC9_CLIENT, Id, Config).


stop(Id) ->
    nkserver_srv_sup:stop(Id).


-spec update(id(), config()) ->
    ok | {error, term()}.

update(Id, Config) ->
    Config2 = nklib_util:to_map(Config),
    Config3 = case Config2 of
        #{plugins:=Plugins} ->
            Config2#{plugins:=[nkrpc9_client|Plugins]};
        _ ->
            Config2
    end,
    nkserver:update(Id, Config3).


%% @doc
send_request(SrvId, Cmd, Data) ->
    case get_pid(SrvId) of
        Pid when is_pid(Pid) ->
            nkrpc9_client_protocol:send_request(Pid, Cmd, Data);
        undefined ->
            {error, no_transports}
    end.


%% @doc
send_async_request(SrvId, Cmd, Data) ->
    case get_pid(SrvId) of
        Pid when is_pid(Pid) ->
            nkrpc9_client_protocol:send_async_request(Pid, Cmd, Data);
        undefined ->
            {error, no_transports}
    end.


%% @doc Send an event to the client
send_event(SrvId, Event, Data) ->
    case get_pid(SrvId) of
        Pid when is_pid(Pid) ->
            nkrpc9_client_protocol:send_event(Pid, Event, Data);
        undefined ->
            {error, no_transports}
    end.


%% @doc Reply to an asynchronous request
reply(#{session_pid:=Pid, tid:=TId}, Reply) ->
    nkrpc9_client_protocol:reply(Pid, TId, Reply).


%% @doc Reply to an asynchronous request updating state
reply(#{session_pid:=Pid, tid:=TId}, Reply, StateFun) ->
    nkrpc9_client_protocol:reply(Pid, TId, Reply, StateFun).


%% @doc
call(SrvId, Msg) ->
    call(SrvId, Msg, 5000).


%% @doc
call(SrvId, Msg, Timeout) ->
    case get_pid(SrvId) of
        Pid when is_pid(Pid) ->
            gen_server:call(Pid, Msg, Timeout);
        undefined ->
            {error, no_transports}
    end.


%% @doc
cast(SrvId, Msg) ->
    case get_pid(SrvId) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, Msg);
        undefined ->
            {error, no_transports}
    end.


%% @private
get_pid(Pid) when is_pid(Pid) ->
    Pid;
get_pid(SrvId) ->
    case nkrpc9_client_protocol:get_local_started(SrvId) of
        [Pid|_] ->
            Pid;
        [] ->
            undefined
    end.
