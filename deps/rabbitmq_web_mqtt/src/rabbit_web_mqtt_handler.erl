%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_web_mqtt_handler).
-behaviour(cowboy_websocket).
-behaviour(cowboy_sub_protocol).

-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).
-export([close_connection/2]).

%% cowboy_sub_protocol
-export([upgrade/4,
         upgrade/5,
         takeover/7]).

-record(state, {
          conn_name,
          parse_state,
          proc_state,
          state,
          conserve_resources,
          socket,
          peername,
          stats_timer,
          received_connect_frame,
          keepalive :: rabbit_mqtt_keepalive:state()
         }).

%% Close frame status codes as defined in https://www.rfc-editor.org/rfc/rfc6455#section-7.4.1
-define(CLOSE_NORMAL, 1000).
-define(CLOSE_PROTOCOL_ERROR, 1002).
-define(CLOSE_INCONSISTENT_MSG_TYPE, 1007).

%%TODO call rabbit_networking:register_non_amqp_connection/1 so that we are notified
%% when need to force load the 'connection_created' event for the management plugin, see
%% https://github.com/rabbitmq/rabbitmq-management-agent/issues/58
%% https://github.com/rabbitmq/rabbitmq-server/blob/90cc0e2abf944141feedaf3190d7b6d8b4741b11/deps/rabbitmq_stream/src/rabbit_stream_reader.erl#L536
%% https://github.com/rabbitmq/rabbitmq-server/blob/90cc0e2abf944141feedaf3190d7b6d8b4741b11/deps/rabbitmq_stream/src/rabbit_stream_reader.erl#L189
%% https://github.com/rabbitmq/rabbitmq-server/blob/7eb4084cf879fe6b1d26dd3c837bd180cb3a8546/deps/rabbitmq_management_agent/src/rabbit_mgmt_db_handler.erl#L72

%% cowboy_sub_protcol
upgrade(Req, Env, Handler, HandlerState) ->
    upgrade(Req, Env, Handler, HandlerState, #{}).

upgrade(Req, Env, Handler, HandlerState, Opts) ->
    cowboy_websocket:upgrade(Req, Env, Handler, HandlerState, Opts).

takeover(Parent, Ref, Socket, Transport, Opts, Buffer, {Handler, HandlerState}) ->
    Sock = case HandlerState#state.socket of
               undefined ->
                   Socket;
               ProxyInfo ->
                   {rabbit_proxy_socket, Socket, ProxyInfo}
           end,
    cowboy_websocket:takeover(Parent, Ref, Socket, Transport, Opts, Buffer,
                              {Handler, HandlerState#state{socket = Sock}}).

%% cowboy_websocket
-spec init(Req, any()) ->
    {ok | module(), Req, any()} |
    {module(), Req, any(), any()}
      when Req::cowboy_req:req().
init(Req, Opts) ->
    {PeerAddr, _PeerPort} = maps:get(peer, Req),
    SockInfo = maps:get(proxy_header, Req, undefined),
    WsOpts0 = proplists:get_value(ws_opts, Opts, #{}),
    %%TODO is compress needed?
    WsOpts  = maps:merge(#{compress => true}, WsOpts0),
    Req2 = case cowboy_req:header(<<"sec-websocket-protocol">>, Req) of
               undefined -> Req;
               %%TODO check whether client offers mqtt:
               %% MQTT spec:
               %% "The Client MUST include “mqtt” in the list of WebSocket Sub Protocols it offers"
               SecWsProtocol ->
                   cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, SecWsProtocol, Req)
           end,
    {?MODULE, Req2, #state{
                       parse_state        = rabbit_mqtt_frame:initial_state(),
                       state              = running,
                       conserve_resources = false,
                       socket             = SockInfo,
                       peername           = PeerAddr,
                       received_connect_frame = false
                      }, WsOpts}.

-spec websocket_init(State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
websocket_init(State0 = #state{socket = Sock, peername = PeerAddr}) ->
    ok = file_handle_cache:obtain(),
    case rabbit_net:connection_string(Sock, inbound) of
        {ok, ConnStr} ->
            State = State0#state{
                      conn_name          = ConnStr,
                      socket             = Sock
                     },
            rabbit_log_connection:info("Accepting Web MQTT connection ~p (~s)", [self(), ConnStr]),
            RealSocket = rabbit_net:unwrap_socket(Sock),
            ProcessorState = rabbit_mqtt_processor:initial_state(RealSocket,
                                                                 ConnStr,
                                                                 fun send_reply/2,
                                                                 PeerAddr),
            process_flag(trap_exit, true),
            {[],
             rabbit_event:init_stats_timer(
               State#state{proc_state = ProcessorState},
               #state.stats_timer),
             hibernate};
        {error, Reason} ->
            {[{shutdown_reason, Reason}], State0}
    end.

-spec close_connection(pid(), string()) -> 'ok'.
close_connection(Pid, Reason) ->
    rabbit_log_connection:info("Web MQTT: will terminate connection process ~tp, reason: ~ts",
                               [Pid, Reason]),
    sys:terminate(Pid, Reason),
    ok.

-spec websocket_handle(ping | pong | {text | binary | ping | pong, binary()}, State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
websocket_handle({binary, Data}, State) ->
    handle_data(Data, State);
%% Silently ignore ping and pong frames as Cowboy will automatically reply to ping frames.
websocket_handle({Ping, _}, State)
  when Ping =:= ping orelse Ping =:= pong ->
    {[], State, hibernate};
websocket_handle(Ping, State)
  when Ping =:= ping orelse Ping =:= pong ->
    {[], State, hibernate};
%% Log any other unexpected frames.
websocket_handle(Frame, State) ->
    rabbit_log_connection:info("Web MQTT: unexpected WebSocket frame ~tp",
                    [Frame]),
    %%TODO close connection instead?
    %%"MQTT Control Packets MUST be sent in WebSocket binary data frames.
    %% If any other type of data frame is received the recipient MUST close the Network Connection"
    {[], State, hibernate}.

-spec websocket_info(any(), State) ->
    {cowboy_websocket:commands(), State} |
    {cowboy_websocket:commands(), State, hibernate}.
websocket_info({conserve_resources, Conserve}, State) ->
    NewState = State#state{conserve_resources = Conserve},
    handle_credits(NewState);
websocket_info({bump_credit, Msg}, State) ->
    credit_flow:handle_bump_msg(Msg),
    handle_credits(State);
websocket_info({reply, Data}, State) ->
    {[{binary, Data}], State, hibernate};
websocket_info({'EXIT', _, _}, State) ->
    stop(State);
websocket_info({'$gen_cast', QueueEvent = {queue_event, _, _}},
               State = #state{proc_state = PState0}) ->
    case rabbit_mqtt_processor:handle_queue_event(QueueEvent, PState0) of
        {ok, PState} ->
            handle_credits(State#state{proc_state = PState});
        {error, Reason, PState} ->
            rabbit_log_connection:error("Web MQTT connection ~p failed to handle queue event: ~p",
                                        [State#state.conn_name, Reason]),
            stop(State#state{proc_state = PState})
    end;
websocket_info({'$gen_cast', duplicate_id}, State = #state{ proc_state = ProcState,
                                                            conn_name = ConnName }) ->
    rabbit_log_connection:warning("Web MQTT disconnecting a client with duplicate ID '~s' (~p)",
                 [rabbit_mqtt_processor:info(client_id, ProcState), ConnName]),
    stop(State);
websocket_info({'$gen_cast', {close_connection, Reason}}, State = #state{ proc_state = ProcState,
                                                                          conn_name = ConnName }) ->
    rabbit_log_connection:warning("Web MQTT disconnecting client with ID '~s' (~p), reason: ~s",
                 [rabbit_mqtt_processor:info(client_id, ProcState), ConnName, Reason]),
    stop(State);
websocket_info({keepalive, Req}, State = #state{keepalive = KState0,
                                                conn_name = ConnName}) ->
    case rabbit_mqtt_keepalive:handle(Req, KState0) of
        {ok, KState} ->
            {[], State#state{keepalive = KState}, hibernate};
        {error, timeout} ->
            rabbit_log_connection:error("keepalive timeout in Web MQTT connection ~p",
                                        [ConnName]),
            stop(State, ?CLOSE_NORMAL, <<"MQTT keepalive timeout">>);
        {error, Reason} ->
            rabbit_log_connection:error("keepalive error in Web MQTT connection ~p: ~p",
                                        [ConnName, Reason]),
            stop(State)
    end;
websocket_info(emit_stats, State) ->
    {[], emit_stats(State), hibernate};
websocket_info({ra_event, _From, Evt},
               #state{proc_state = PState0} = State) ->
    PState = rabbit_mqtt_processor:handle_ra_event(Evt, PState0),
    {[], State#state{proc_state = PState}, hibernate};
websocket_info({{'DOWN', _QName}, _MRef, process, _Pid, _Reason} = Evt,
               State = #state{proc_state = PState0}) ->
    case rabbit_mqtt_processor:handle_down(Evt, PState0) of
        {ok, PState} ->
            handle_credits(State#state{proc_state = PState});
        {error, Reason} ->
            stop(State, ?CLOSE_NORMAL, Reason)
    end;
websocket_info({'DOWN', _MRef, process, QPid, _Reason}, State) ->
    rabbit_amqqueue_common:notify_sent_queue_down(QPid),
    {[], State, hibernate};
websocket_info(Msg, State) ->
    rabbit_log_connection:warning("Web MQTT: unexpected message ~p", [Msg]),
    {[], State, hibernate}.

-spec terminate(any(), cowboy_req:req(), any()) -> ok.
terminate(_Reason, _Request,
          #state{conn_name = ConnName,
                 proc_state = PState,
                 keepalive = KState} = State) ->
    rabbit_log_connection:info("closing Web MQTT connection ~p (~s)", [self(), ConnName]),
    maybe_emit_stats(State),
    rabbit_mqtt_keepalive:cancel_timer(KState),
    ok = file_handle_cache:release(),
    stop_rabbit_mqtt_processor(PState, ConnName).

%% Internal.

handle_data(Data, State0 = #state{conn_name = ConnStr}) ->
    case handle_data1(Data, State0) of
        {ok, State1 = #state{state = blocked}, hibernate} ->
            {[{active, false}], State1, hibernate};
        {error, Error} ->
            stop_with_framing_error(State0, Error, ConnStr);
        Other ->
            Other
    end.

handle_data1(<<>>, State0 = #state{received_connect_frame = false,
                                   proc_state = PState,
                                   conn_name = ConnStr}) ->
    rabbit_log_connection:info("Accepted web MQTT connection ~p (~s, client id: ~s)",
                               [self(), ConnStr, rabbit_mqtt_processor:info(client_id, PState)]),
    State = State0#state{received_connect_frame = true},
    {ok, ensure_stats_timer(control_throttle(State)), hibernate};
handle_data1(<<>>, State) ->
    {ok, ensure_stats_timer(control_throttle(State)), hibernate};
handle_data1(Data, State = #state{ parse_state = ParseState,
                                       proc_state  = ProcState,
                                       conn_name   = ConnStr }) ->
    case rabbit_mqtt_frame:parse(Data, ParseState) of
        {more, ParseState1} ->
            {ok, ensure_stats_timer(control_throttle(
                State #state{ parse_state = ParseState1 })), hibernate};
        {ok, Frame, Rest} ->
            case rabbit_mqtt_processor:process_frame(Frame, ProcState) of
                {ok, ProcState1} ->
                    PS = rabbit_mqtt_frame:initial_state(),
                    handle_data1(
                      Rest,
                      State#state{parse_state = PS,
                                  proc_state = ProcState1});
                {error, Reason, _} ->
                    rabbit_log_connection:info("MQTT protocol error ~tp for connection ~tp",
                        [Reason, ConnStr]),
                    stop(State, ?CLOSE_PROTOCOL_ERROR, Reason);
                {error, Error} ->
                    stop_with_framing_error(State, Error, ConnStr);
                {stop, _} ->
                    stop(State)
            end;
        Other ->
            Other
    end.

stop_with_framing_error(State, Error0, ConnStr) ->
    Error1 = rabbit_misc:format("~tp", [Error0]),
    rabbit_log_connection:error("MQTT detected framing error '~ts' for connection ~tp",
                                [Error1, ConnStr]),
    stop(State, ?CLOSE_INCONSISTENT_MSG_TYPE, Error1).

stop(State) ->
    stop(State, ?CLOSE_NORMAL, "MQTT died").

stop(State, CloseCode, Error0) ->
    Error = rabbit_data_coercion:to_binary(Error0),
    {[{close, CloseCode, Error}], State}.

stop_rabbit_mqtt_processor(undefined, _) ->
    ok;
stop_rabbit_mqtt_processor(PState, ConnName) ->
    rabbit_mqtt_processor:send_will(PState),
    rabbit_mqtt_processor:terminate(PState, ConnName).

handle_credits(State0) ->
    %%TODO return hibernate?
    case control_throttle(State0) of
        State = #state{state = running} ->
            {[{active, true}], State};
        State ->
            {[], State}
    end.

control_throttle(State = #state{state = CS,
                                conserve_resources = Conserve,
                                keepalive = KState,
                                proc_state = PState}) ->
    Throttle = Conserve orelse
    rabbit_mqtt_processor:soft_limit_exceeded(PState) orelse
    credit_flow:blocked(),
    case {CS, Throttle} of
        {running, true} ->
            State#state{state = blocked,
                        keepalive = rabbit_mqtt_keepalive:cancel_timer(KState)};
        {blocked,false} ->
            State#state{state = running,
                        keepalive = rabbit_mqtt_keepalive:start_timer(KState)};
        {_, _} ->
            State
    end.

send_reply(Frame, PState) ->
    self() ! {reply, rabbit_mqtt_processor:serialise(Frame, PState)}.

ensure_stats_timer(State) ->
    rabbit_event:ensure_stats_timer(State, #state.stats_timer, emit_stats).

%% TODO if #state.stats_timer is undefined, rabbit_event:if_enabled crashes
maybe_emit_stats(State) ->
    rabbit_event:if_enabled(State, #state.stats_timer,
                                fun() -> emit_stats(State) end).

emit_stats(State=#state{received_connect_frame = false}) ->
    %% Avoid emitting stats on terminate when the connection has not yet been
    %% established, as this causes orphan entries on the stats database
    State1 = rabbit_event:reset_stats_timer(State, #state.stats_timer),
    State1;
emit_stats(State=#state{socket=Sock, state=RunningState}) ->
    SockInfos = case rabbit_net:getstat(Sock,
            [recv_oct, recv_cnt, send_oct, send_cnt, send_pend]) of
        {ok,    SI} -> SI;
        {error,  _} -> []
    end,
    Infos = [{pid, self()}, {state, RunningState}|SockInfos],
    rabbit_core_metrics:connection_stats(self(), Infos),
    State1 = rabbit_event:reset_stats_timer(State, #state.stats_timer),
    State1.
