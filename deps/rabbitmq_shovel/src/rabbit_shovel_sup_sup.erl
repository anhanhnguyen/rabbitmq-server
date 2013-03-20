%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is VMware, Inc.
%%  Copyright (c) 2007-2013 VMware, Inc.  All rights reserved.
%%

-module(rabbit_shovel_sup_sup).
-behaviour(mirrored_supervisor).

-export([start_link/0, init/1]).

start_link() ->
    mirrored_supervisor:start_link({local, ?MODULE}, ?MODULE, ?MODULE, []).

init([]) ->
    ChildSpecs = [{rabbit_shovel_status,
                   {rabbit_shovel_status, start_link, []},
                   transient, 16#ffffffff, worker, [rabbit_shovel_status]},
                  {rabbit_shovel_sup,
                   {rabbit_shovel_sup, start_link, []},
                   permanent, 16#ffffffff, supervisor, [rabbit_shovel_sup]}],
    {ok, {{one_for_one, 3, 10}, ChildSpecs}}.
