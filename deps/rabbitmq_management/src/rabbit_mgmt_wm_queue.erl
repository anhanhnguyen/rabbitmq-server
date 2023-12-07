%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.  All rights reserved.
%%

-module(rabbit_mgmt_wm_queue).

-export([init/2, resource_exists/2, to_json/2,
         content_types_provided/2, content_types_accepted/2,
         is_authorized/2, allowed_methods/2, accept_content/2,
         delete_resource/2, queue/1, queue/2]).
-export([variances/2]).

-include_lib("rabbitmq_management_agent/include/rabbit_mgmt_records.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%%--------------------------------------------------------------------

init(Req, _State) ->
    {cowboy_rest, rabbit_mgmt_headers:set_common_permission_headers(Req, ?MODULE), #context{}}.

variances(Req, Context) ->
    {[<<"accept-encoding">>, <<"origin">>], Req, Context}.

content_types_provided(ReqData, Context) ->
   {rabbit_mgmt_util:responder_map(to_json), ReqData, Context}.

content_types_accepted(ReqData, Context) ->
    {[{'*', accept_content}], ReqData, Context}.

allowed_methods(ReqData, Context) ->
    {[<<"HEAD">>, <<"GET">>, <<"PUT">>, <<"DELETE">>, <<"OPTIONS">>], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {case queue(ReqData) of
         not_found -> false;
         _         -> true
     end, ReqData, Context}.

to_json(ReqData, Context) ->
    try
        case rabbit_mgmt_util:disable_stats(ReqData) of
            false ->
                [Q] = rabbit_mgmt_db:augment_queues(
                        [queue(ReqData)], rabbit_mgmt_util:range_ceil(ReqData),
                        full),
                Payload = rabbit_mgmt_format:clean_consumer_details(
                            rabbit_mgmt_format:strip_pids(Q)),
                rabbit_mgmt_util:reply(ensure_defaults(Payload), ReqData, Context);
            true ->
                rabbit_mgmt_util:reply(rabbit_mgmt_format:strip_pids(queue(ReqData)),
                                       ReqData, Context)
        end
    catch
        {error, invalid_range_parameters, Reason} ->
            rabbit_mgmt_util:bad_request(iolist_to_binary(Reason), ReqData, Context)
    end.

accept_content(ReqData, Context) ->
    Name = rabbit_mgmt_util:id(queue, ReqData),
    %% NOTE: ?FRAMING currently defined as 0.9.1 hence validating length
    case rabbit_parameter_validation:amqp091_queue_name(queue, Name) of
        ok ->
            rabbit_mgmt_util:direct_request(
            'queue.declare',
            fun rabbit_mgmt_format:format_accept_content/1,
            [{queue, Name}], "Declare queue error: ~ts", ReqData, Context);
        {error, F, A} ->
            rabbit_mgmt_util:bad_request(iolist_to_binary(io_lib:format(F ++ "~n", A)), ReqData, Context)
    end.

delete_resource(ReqData, Context = #context{user = #user{username = ActingUser}}) ->
    %% We need to retrieve manually if-unused and if-empty, as the HTTP API uses '-'
    %% while the record uses '_'
    IfUnused = <<"true">> =:= rabbit_mgmt_util:qs_val(<<"if-unused">>, ReqData),
    IfEmpty = <<"true">> =:= rabbit_mgmt_util:qs_val(<<"if-empty">>, ReqData),
    VHost = rabbit_mgmt_util:id(vhost, ReqData),
    QName = rabbit_mgmt_util:id(queue, ReqData),
    Name = rabbit_misc:r(VHost, queue, QName),
    case rabbit_amqqueue:lookup(Name) of
        {ok, Q} ->
            IsExclusive = amqqueue:is_exclusive(Q),
            ExclusiveOwnerPid = amqqueue:get_exclusive_owner(Q),
            try rabbit_amqqueue:delete_with(Q, ExclusiveOwnerPid, IfUnused, IfEmpty, ActingUser, IsExclusive) of
                {ok, _} ->
                    {true, ReqData, Context}
            catch
                _:#amqp_error{explanation = Explanation} ->
                    rabbit_log:warning("Delete queue error: ~ts", [Explanation]),
                    rabbit_mgmt_util:bad_request(list_to_binary(Explanation), ReqData, Context)
            end;
        {error, not_found} ->
            {true, ReqData, Context}
   end.

is_authorized(ReqData, Context) ->
    VHost = rabbit_mgmt_util:id(vhost, ReqData),
    QName = rabbit_mgmt_util:id(queue, ReqData),
    QRes  = rabbit_misc:r(VHost, queue, QName),
    rabbit_mgmt_util:is_authorized_vhost_and_has_resource_permission(ReqData, Context, QRes, configure).

%%--------------------------------------------------------------------

%% this is here to ensure certain data points are always there. When a queue
%% is moved there can be transient periods where certain advanced metrics aren't
%% yet available on the new node.
ensure_defaults(Payload0) ->
    case lists:keyfind(garbage_collection, 1, Payload0) of
        {_K, _V} -> Payload0;
        false ->
            [{garbage_collection,
              [{max_heap_size,-1},
               {min_bin_vheap_size,-1},
               {min_heap_size,-1},
               {fullsweep_after,-1},
               {minor_gcs,-1}]} | Payload0]
    end.

queue(ReqData) ->
    case rabbit_mgmt_util:vhost(ReqData) of
        not_found -> not_found;
        VHost     -> queue(VHost, rabbit_mgmt_util:id(queue, ReqData))
    end.


queue(VHost, QName) ->
    Name = rabbit_misc:r(VHost, queue, QName),
    case rabbit_amqqueue:lookup(Name) of
        {ok, Q}            -> rabbit_mgmt_format:queue(Q);
        {error, not_found} -> not_found
    end.
