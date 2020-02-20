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

%% @doc
-module(nkrpc9_process).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([request/5, event/5, result/6]).
-import(nkserver_trace, [trace/1, trace/2]).

-include_lib("nkserver/include/nkserver.hrl").

%% @doc
request(SrvId, Cmd, Data, Req, State) ->
    request_parse(SrvId, Cmd, Data, Req, State).


%% @doc
event(SrvId, Event, Data, Req, State) ->
    event_parse(SrvId, Event, Data, Req, State).


%% @doc
result(SrvId, Result, Data, Op, From, State) ->
    trace("rpc9 result: ~p", [Result]),
    case ?CALL_SRV(SrvId, rpc9_result, [Result, Data, Op, From, State]) of
        {reply, _Result2, _Data2, State2} when From==undefined ->
            {ok, State2};
        {reply, Result2, Data2, State2} ->
            gen_server:reply(From, {ok, Result2, Data2}),
            {ok, State2};
        {noreply, State2} ->
            {ok, State2}
    end.


%% @private
request_parse(SrvId, Cmd, Data, Req, State) ->
    trace("rpc9 parsing request"),
    case ?CALL_SRV(SrvId, rpc9_parse, [Cmd, Data, Req, State]) of
        {syntax, Syntax} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, []} ->
                    request_allow(SrvId, Cmd, Data2, Req, State);
                {ok, Data2, Unknown} ->
                    Req2 = Req#{unknown_fields => Unknown},
                    request_allow(SrvId, Cmd, Data2, Req2, State);
                {error, Error} ->
                    {error, Error, State}
            end;
        {syntax, Syntax, State2} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, []} ->
                    request_allow(SrvId, Cmd, Data2, Req, State2);
                {ok, Data2, Unknown} ->
                    Req2 = Req#{unknown_fields => Unknown},
                    request_allow(SrvId, Cmd, Data2, Req2, State2);
                {error, Error} ->
                    {error, Error, State2}
            end;
        {ok, Data2} ->
            request_allow(SrvId, Cmd, Data2, Req, State);
        {ok, Data2, State2} ->
            request_allow(SrvId, Cmd, Data2, Req, State2);
        {status, Status} ->
            trace("rpc9 processed status: ~p", [Status]),
            {status, Status, State};
        {status, Status, State2} ->
            trace("rpc9 processed status: ~p", [Status]),
            {status, Status, State2};
        {error, Error} ->
            trace("rpc9 processed error: ~p", [Error]),
            {error, Error, State};
        {error, Error, State2} ->
            trace("rpc9 processed error: ~p", [Error]),
            {error, Error, State2};
        {stop, Reason, Reply} ->
            trace("rpc9 processed stop: ~p", [Reason]),
            {stop, Reason, Reply, State};
        {stop, Reason, Reply, State2} ->
            trace("rpc9 processed stop: ~p", [Reason]),
            {stop, Reason, Reply, State2}
    end.


%% @private
request_allow(SrvId, Cmd, Data, Req, State) ->
    trace("rpc9 allowing request"),
    case ?CALL_SRV(SrvId, rpc9_allow, [Cmd, Data, Req, State]) of
        true ->
            request_process(SrvId, Cmd, Data, Req, State);
        {true, State2} ->
            request_process(SrvId, Cmd, Data, Req, State2);
        false ->
            trace("rpc9 request NOT allowed"),
            {error, unauthorized, State}
    end.


%% @private
request_process(SrvId, Cmd, Data, Req, State) ->
    trace("rpc9 request allowed"),
    case ?CALL_SRV(SrvId, rpc9_request, [Cmd, Data, Req, State]) of
        {login, UserId, Reply} ->
            trace("rpc9 processed login: ~s", [UserId]),
            {login, UserId, check_unknown(Reply, Req), State};
        {login, UserId, Reply, State2} ->
            trace("rpc9 processed login: ~s", [UserId]),
            {login, UserId, check_unknown(Reply, Req), State2};
        {reply, Reply, State2} ->
            trace("rpc9 processed reply"),
            {reply, check_unknown(Reply, Req), State2};
        {reply, Reply} ->
            trace("rpc9 processed reply"),
            {reply, check_unknown(Reply, Req), State};
        ack ->
            trace("rpc9 processed ack"),
            {ack, undefined, State};
        {ack, Pid} ->
            trace("rpc9 processed ack"),
            {ack, Pid, State};
        {ack, Pid, State2} ->
            trace("rpc9 processed ack"),
            {ack, Pid, State2};
        {status, Status} ->
            trace("rpc9 processed status: ~p", [Status]),
            {status, Status, State};
        {status, Status, State2} ->
            trace("rpc9 processed status: ~p", [Status]),
            {status, Status, State2};
        {error, Error} ->
            trace("rpc9 processed error: ~p", [Error]),
            {error, Error, State};
        {error, Error, State2} ->
            trace("rpc9 processed error: ~p", [Error]),
            {error, Error, State2};
        {stop, Reason, Reply} ->
            trace("rpc9 processed stop: ~p", [Reason]),
            {stop, Reason, Reply, State};
        {stop, Reason, Reply, State2} ->
            trace("rpc9 processed stop: ~p", [Reason]),
            {stop, Reason, Reply, State2}
    end.


%% @private
event_parse(SrvId, Event, Data, Req, State) ->
    trace("parsing event"),
    case ?CALL_SRV(SrvId, rpc9_parse, [Event, Data, Req, State]) of
        {syntax, Syntax, State2} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, _} ->
                    event_process(SrvId, Event, Data2, Req, State2);
                {error, Error} ->
                    {error, Error, State2}
            end;
        {syntax, Syntax} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, _} ->
                    event_process(SrvId, Event, Data2, Req, State);
                {error, Error} ->
                    {error, Error, State}
            end;
        {ok, Data2} ->
            event_process(SrvId, Event, Data2, Req, State);
        {ok, Data2, State2} ->
            event_process(SrvId, Event, Data2, Req, State2);
        {error, Error} ->
            {error, Error, State};
        {error, Error, State2} ->
            {error, Error, State2};
        {stop, Reason} ->
            {stop, Reason, State};
        {stop, Reason, State2} ->
            {stop, Reason, State2}
    end.


%% @private
event_process(SrvId, Event, Data, Req, State) ->
    case ?CALL_SRV(SrvId, rpc9_event, [Event, Data, Req, State]) of
        ok ->
            {ok, State};
        {ok, State2} ->
            {ok, State2};
        {error, Error} ->
            {error, Error};
        {error, Error, State2} ->
            {error, Error, State2};
        {stop, Reason} ->
            {stop, Reason, State};
        {stop, Reason, State2} ->
            {stop, Reason, State2}
    end.


%% @private
check_unknown(Reply, Req) ->
    case maps:find(unknown_fields, Req) of
        {ok, Fields} ->
            trace("unknown fields: ~p", [Fields]),
            Reply#{unknown_fields=>Fields};
        error ->
            Reply
    end.
