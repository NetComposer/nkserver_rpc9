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
-module(nkrpc9_server_http).
-export([is_http/1, get_headers/1, get_qs/1, get_basic_auth/1, get_ct/1]).
-export([iter_body/4, stream_start/3, stream_body/2, stream_stop/1]).
-export([init/4, terminate/3]).
-export_type([method/0, reply/0, code/0, headers/0, body/0, req/0, path/0, http_qs/0]).


-define(DEBUG(Txt, Args, State),
    case erlang:get(nkrpc9_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type("NkSERVER RPC9 HTTP (~s, ~s) "++Txt,
               [maps:get(srv, Req), maps:get(remote, Req)|Args])).

-include_lib("nkserver/include/nkserver.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nkrpc9.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type method() :: binary().         %% <<"GET">> ...

-type code() :: 100 .. 599.

-type headers() :: #{binary() => iolist()}.

-type body() ::  Body::binary()|map().

-type http_qs() ::
    [{binary(), binary()|true}].

-type path() :: [binary()].

-type req() ::
    #{
        srv => nkserver:id(),
        method => method(),
        path => [binary()],
        peer => binary(),
        external_url => binary(),
        content_type => binary(),
        cowboy_req => term()
    }.


-type reply() ::
    {http, code(), headers(), body(), req()}.


%% ===================================================================
%% Public functions
%% ===================================================================


-spec is_http(req()) ->
    headers().

is_http(#{'_cowreq':=_}) -> true;
is_http(_) -> false.


-spec get_headers(req()) ->
    headers().

get_headers(#{'_cowreq':=CowReq}) ->
    cowboy_req:headers(CowReq).


%% @doc
-spec get_qs(req()) ->
    http_qs().

get_qs(#{'_cowreq':=CowReq}) ->
    cowboy_req:parse_qs(CowReq).


%% @doc
-spec get_basic_auth(req()) ->
    {ok, binary(), binary()} | undefined.

get_basic_auth(#{'_cowreq':=CowReq}) ->
    case cowboy_req:parse_header(<<"authorization">>, CowReq) of
        {basic, User, Pass} ->
            {ok, User, Pass};
        _ ->
            undefined
    end.

%% @doc
-spec get_ct(req()) ->
    {binary(), binary(), list()}.

get_ct(#{'_cowreq':=CowReq}) ->
    cowboy_req:parse_header(<<"content-type">>, CowReq).


-type iter_function() :: fun((binary(), term()) -> term()).
-type iter_opts() :: #{max_chunk_size=>integer(), max_chunk_time=>integer()}.


%% @doc
-spec iter_body(req(), iter_function(), term(), iter_opts()) ->
    {term(), req()}.

iter_body(#{'_cowreq':=CowReq}=Req, Opts, Fun, Acc0) ->
    case do_iter_body(CowReq, Opts, Fun, Acc0) of
        {ok, Result, CowReq2} ->
            {ok, Result, Req#{'_cowreq':=CowReq2}};
        {error, Error, CowReq2} ->
            {error, Error, Req#{'_cowreq':=CowReq2}}
    end.


%% @private
do_iter_body(CowReq, Opts, Fun, Acc) ->
    MaxChunkSize = maps:get(max_chunk_size, Opts, 8*1024*1024),
    MaxChunkTime = maps:get(max_chunk_time, Opts, 15000),
    Opts2 = #{length => MaxChunkSize, period => MaxChunkTime},
    {Res, Data, CowReq2} = cowboy_req:read_body(CowReq, Opts2),
    case Fun(Data, Acc) of
        {ok, Acc2} when Res==ok ->
            {ok, Acc2, CowReq2};
        {ok, Acc2} when Res==more ->
            ?MODULE:do_iter_body(CowReq2, Opts, Fun, Acc2);
        {error, Error} ->
            {error, Error, CowReq2}
    end.


%% @doc Streamed responses
%% First, call this function
%% Then call stream_body/2 for each chunk, and finish with {stop, Req}

stream_start(Code, Hds, #{'_cowreq':=CowReq}=Req) when is_map(Hds) ->
    CowReq2 = nkpacket_cowboy:stream_reply(Code, Hds, CowReq),
    Req#{'_cowreq':=CowReq2};

stream_start(Code, Hds, Req) when is_list(Hds) ->
    stream_start(Code, maps:from_list(Hds), Req).


%% @doc
stream_body(Body, #{'_cowreq':=CowReq}) ->
    ok = nkpacket_cowboy:stream_body(Body, nofin, CowReq).


%% @doc
stream_stop(#{'_cowreq':=CowReq}) ->
    ok = nkpacket_cowboy:stream_body(<<>>, fin, CowReq).


%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
%% Called from middle9_server_protocol:http_init/5
init(Method, Path, CowReq, NkPort) ->
    Local = nkpacket:get_local_bin(NkPort),
    {Ip, Port} = cowboy_req:peer(CowReq),
    Remote = <<
        (nklib_util:to_host(Ip))/binary, ":",
        (to_bin(Port))/binary
    >>,
    {ok, _Class, {nkrpc9_server, SrvId}} = nkpacket:get_id(NkPort),
    set_debug(SrvId),
    SessionId = nklib_util:luid(),
    Req = #{
        srv => SrvId,
        start => nklib_util:l_timestamp(),
        session_id => SessionId,
        session_pid => self(),
        local => Local,
        remote => Remote,
        tid => erlang:phash2(SessionId),
        timeout_pending => false,
        debug => get(nkrpc9_debug),
        '_cowreq' => CowReq
    },
    try
        case Method of
            <<"POST">> when Path == [] ->
                {ok, Cmd, Data, CowReq2} = get_cmd_body(SrvId, CowReq),
                Req2 = Req#{
                    cmd => Cmd,
                    data => Data,
                    '_cowreq' := CowReq2
                },
                case nkrpc9_process:request(SrvId, Cmd, Data, Req2, #{}) of
                    {login, _UserId, Reply, _State} ->
                        send_msg_ok(Reply, CowReq2);
                    {reply, Reply, _State} ->
                        send_msg_ok(Reply, CowReq2);
                    {ack, Pid, _State} ->
                        Mon = case is_pid(Pid) of
                            true ->
                                monitor(process, Pid);
                            false ->
                                undefined
                        end,
                        wait_ack(Req, Mon);
                    {error, Error, _State} ->
                        send_msg_error(SrvId, Error, CowReq2)
                end;
            _ ->
                case ?CALL_SRV(SrvId, rpc9_http, [Method, Path, Req]) of
                    {http, Code, RHds, RBody, #{'_cowreq':=CowReq3}} ->
                        send_http_reply(Code, RHds, RBody, CowReq3);
                    {stop, #{'_cowreq':=CowReq3}} ->
                        ?DEBUG("replying stream stop", [], Req),
                        {ok, CowReq3, []};
                    {redirect, Path} ->
                        {redirect, Path};
                    {cowboy_static, Opts} ->
                        {cowboy_static, Opts}
                end
        end
    catch
        throw:{TCode, THds, TReply} ->
            send_http_reply(TCode, THds, TReply, CowReq)
    end.


%% @private
terminate(_Reason, _Req, _Opts) ->
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
set_debug(SrvId) ->
    Debug = nkserver:get_plugin_config(SrvId, nkrpc9_server, debug),
    Http = lists:member(protocol, Debug),
    put(nkrpc9_debug, Http).


%% @private
get_cmd_body(SrvId, CowReq) ->
    MaxBody = nkserver:get_plugin_config(SrvId, nkrpc9_server, http_max_body),
    case cowboy_req:body_length(CowReq) of
        BL when is_integer(BL), BL =< MaxBody ->
            %% https://ninenines.eu/docs/en/cowboy/2.1/guide/req_body/



            {ok, Body, CowReq2} = cowboy_req:read_body(CowReq, #{length=>infinity}),
              case cowboy_req:header(<<"content-type">>, CowReq) of
                <<"application/json">> ->
                    case nklib_json:decode(Body) of
                        error ->
                            throw({400, #{}, <<"Invalid json">>});
                        #{<<"cmd">>:=Cmd}=Json ->
                            Data = maps:get(<<"data">>, Json, #{}),
                            {ok, Cmd, Data, CowReq2};
                        _ ->
                            throw({400, <<"Invalid API body">>})
                    end;
                _ ->
                    throw({400, #{}, <<"Invalid Content-Type">>})
            end;
        BL ->
            lager:error("NKLOG Body is too large ~p", [BL]),
            throw({500, #{}, <<"Body too large">>})
    end.


%% @private
wait_ack(#{srv:=SrvId, tid:=TId, '_cowreq':=CowReq}=Req, Mon) ->
    ExtTime = nkserver:get_plugin_config(SrvId, nkrpc9_server, ext_cmd_timeout),
    receive
        {'$gen_cast', {rpc9_reply_login, _UserId, Reply, TId, _StateFun}} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, CowReq);
        {'$gen_cast', {rpc9_reply_ok, Reply, TId, _StateFun}} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, CowReq);
        {'$gen_cast', {rpc9_reply_error, Error, TId, _StateFun}} ->
            nklib_util:demonitor(Mon),
            send_msg_error(SrvId, Error, CowReq);
        {'$gen_cast', {rpc9_reply_ack, undefined, TId, _StateFun}} ->
            wait_ack(Req, Mon);
        {'$gen_cast', {rpc9_reply_ack, Pid, TId, _StateFun}} when is_pid(Pid) ->
            nklib_util:demonitor(Mon),
            Mon2 = monitor(process, Pid),
            wait_ack(Req, Mon2);
        {'DOWN', Mon, process, _Pid, _Reason} ->
            send_msg_error(SrvId, process_down, CowReq);
        {'$gen_cast', rpc9_stop} ->
            ok;
        Other ->
            ?LLOG(warning, "unexpected msg in wait_ack: ~p", [Other], Req),
            wait_ack(Req, Mon)
    after
        ExtTime ->
            nklib_util:demonitor(Mon),
            send_msg_error(timeout, Req, CowReq)
    end.


%% @private
send_msg_ok(Reply, CowReq) ->
    Msg1 = #{result=>ok},
    Msg2 = case Reply of
        #{} when map_size(Reply)==0 -> Msg1;
        #{} -> Msg1#{data=>Reply};
        List when is_list(List) -> Msg1#{data=>Reply}
    end,
    send_http_reply(200, #{}, Msg2, CowReq).


%% @private
send_msg_error(SrvId, Error, CowReq) ->
    {Code, Text} = nkserver_msg:msg(SrvId, Error),
    Msg = #{
        result => error,
        data => #{
            code => Code,
            error => Text
        }
    },
    send_http_reply(200, #{}, Msg, CowReq).


%% @private
send_http_reply(Code, Hds, Body, CowReq) when is_map(Hds) ->
    {Hds2, Body2} = case is_map(Body) orelse is_list(Body) of
        true ->
            {
                Hds#{<<"content-type">> => <<"application/json">>},
                nklib_json:encode(Body)
            };
        false ->
            {
                Hds,
                to_bin(Body)
            }
    end,
    {ok, cowboy_req:reply(Code, Hds2, Body2, CowReq), []};

send_http_reply(Code, Hds, Body, CowReq) when is_list(Hds) ->
    send_http_reply(Code, maps:from_list(Hds), Body, CowReq).




%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
