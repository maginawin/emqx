%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn_postgresql).

-behaviour(emqx_authn_provider).

-export([
    create/2,
    update/2,
    authenticate/2,
    destroy/1
]).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-include_lib("emqx_auth/include/emqx_authn.hrl").
-include_lib("epgsql/include/epgsql.hrl").
-include("emqx_auth_postgresql.hrl").

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

create(_AuthenticatorID, Config) ->
    create(Config).

create(Config0) ->
    ResourceId = emqx_authn_utils:make_resource_id(?AUTHN_BACKEND_BIN),
    {Config, State} = parse_config(Config0, ResourceId),
    {ok, _Data} = emqx_authn_utils:create_resource(
        ResourceId,
        emqx_postgresql,
        Config,
        ?AUTHN_MECHANISM_BIN,
        ?AUTHN_BACKEND_BIN
    ),
    {ok, State#{resource_id => ResourceId}}.

update(Config0, #{resource_id := ResourceId} = _State) ->
    {Config, NState} = parse_config(Config0, ResourceId),
    case
        emqx_authn_utils:update_resource(
            emqx_postgresql, Config, ResourceId, ?AUTHN_MECHANISM_BIN, ?AUTHN_BACKEND_BIN
        )
    of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, _} ->
            {ok, NState#{resource_id => ResourceId}}
    end.

destroy(#{resource_id := ResourceId}) ->
    _ = emqx_resource:remove_local(ResourceId),
    ok.

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(#{password := undefined}, _) ->
    {error, bad_username_or_password};
authenticate(
    #{password := Password} = Credential,
    #{
        placeholders := PlaceHolders,
        resource_id := ResourceId,
        password_hash_algorithm := Algorithm,
        cache_key_template := CacheKeyTemplate
    }
) ->
    Params = emqx_auth_template:render_sql_params(PlaceHolders, Credential),
    CacheKey = emqx_auth_template:cache_key(Credential, CacheKeyTemplate),
    case
        emqx_authn_utils:cached_simple_sync_query(
            CacheKey, ResourceId, {prepared_query, ResourceId, Params}
        )
    of
        {ok, _Columns, []} ->
            ignore;
        {ok, Columns, [Row | _]} ->
            NColumns = [Name || #column{name = Name} <- Columns],
            Selected = maps:from_list(lists:zip(NColumns, erlang:tuple_to_list(Row))),
            case
                emqx_authn_utils:check_password_from_selected_map(
                    Algorithm, Selected, Password
                )
            of
                ok ->
                    {ok, emqx_authn_utils:is_superuser(Selected)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER(error, "postgresql_query_failed", #{
                resource => ResourceId,
                params => Params,
                reason => Reason
            }),
            ignore
    end.

parse_config(
    #{
        query := Query0,
        password_hash_algorithm := Algorithm
    } = Config,
    ResourceId
) ->
    ok = emqx_authn_password_hashing:init(Algorithm),
    {Vars, Query, PlaceHolders} = emqx_authn_utils:parse_sql(Query0, '$n'),
    CacheKeyTemplate = emqx_auth_template:cache_key_template(Vars),
    State = #{
        placeholders => PlaceHolders,
        password_hash_algorithm => Algorithm,
        cache_key_template => CacheKeyTemplate
    },
    {Config#{prepare_statement => #{ResourceId => Query}}, State}.
