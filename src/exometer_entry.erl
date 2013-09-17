-module(exometer_entry).

-export([new/2,
	 new/3,
	 update/2,
	 get_value/1,
	 sample/1,
	 delete/1,
	 reset/1,
	 setopts/2,
	 find_entries/1,
	 select/1, select/2,
	 info/1,
	 info/2]).

-include("exometer.hrl").
-include("log.hrl").

-export_type([name/0, type/0, options/0, value/0, ref/0, error/0]).

-type name()     :: list().
-type type()     :: atom().
-type options()  :: [{atom(), any()}].
-type value()    :: any().
-type ref()      :: pid() | undefined.
-type error()   :: { error, any() }.

-callback new(name(), type(), options()) ->
    ok | {ok, pid()} | error().
-callback delete(name(), type(), ref()) ->
    ok | error().
-callback get_value(name(), type(), ref()) ->
    {ok, value() | unavailable} | error().
-callback update(name(), value(), type(), ref()) ->
    ok | {ok, value()} | error().
-callback reset(name(), type(), ref()) ->
    ok | {ok, value()} | error().
-callback sample(name(), type(), ref()) ->
    ok | error().
-callback setopts(name(), options(), type(), ref()) ->
    ok | error().


new(Name, Type) ->
    new(Name, Type, []).

-spec new(name(), type(), options()) -> ok.

new(Name, Type0, Opts0) when is_list(Name), is_list(Opts0) ->
    {Type,Opts} = if is_tuple(Type0) -> {element(1,Type0),
					 [{type_arg, Type0}|Opts0]};
		     true -> {Type0, Opts0}
		  end,
    #exometer_entry{} = E = exometer_admin:lookup_definition(Name, Type),
    create_entry(E#exometer_entry { name = Name }, Opts).



-spec update(name(), value()) -> ok | error().
update(Name, Value) when is_list(Name) ->
    case ets:lookup(Table = exometer:table(), Name) of
	[#exometer_entry{module = ?MODULE, type = counter}] ->
	    ets:update_counter(Table, Name, {#exometer_entry.value, Value}),
	    ok;
	[#exometer_entry{module = M, type = Type, ref = Ref}] ->
	    M:update(Name, Value, Type, Ref);
	[] ->
	    {error, not_found}
    end.


-spec get_value(name()) -> {ok, value()} | error().
get_value(Name) when is_list(Name) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{} = E] ->
	    {ok, get_value_(E)};
	_ ->
	    {error, not_found}
    end.

get_value_(#exometer_entry{status = Status,
			   name = Name, module = ?MODULE, type = counter}) ->
    if Status == enabled ->
	    lists:sum([ets:lookup_element(T, Name, #exometer_entry.value)
		       || T <- exometer:tables()]);
       Status == disabled ->
	    unavailable
    end;
get_value_(#exometer_entry{status = Status, cache = Cache,
			   name = Name, module = M, type = Type, ref = Ref}) ->
    if Status == enabled ->
	    if Cache > 0 ->
		    case exometer_cache:read(Name) of
			{ok, Value} -> Value;
			error ->
			    cache(Cache, Name,
				  M:get_value(Name, Type, Ref))
		    end;
	       Cache == 0 ->
		    M:get_value(Name, Type, Ref)
	    end;
       Status == disabled ->
	    unavailable
    end.

-spec delete(name()) -> ok | error().
delete(Name) when is_list(Name) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{module = ?MODULE, type = counter}] ->
	    [ets:delete(T, Name) || T <- exometer:tables()];
	[#exometer_entry{module = M, type = Type, ref = Ref}] ->
	    try M:delete(Name, Type, Ref)
	    after
		[ets:delete(T, Name) || T <- exometer:tables()]
	    end;
	[] ->
	    {error, not_found}
    end.


-spec sample(name()) -> ok | error().
sample(Name)  when is_list(Name) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{status = enabled,
			 module = M, type = Type, ref = Ref}] ->
	    M:sample(Name, Type, Ref);
	[#exometer_entry{status = disabled}] ->
	    ok;
	[] ->
	    {error, not_found}
    end.


-spec reset(name()) -> ok | error().
reset(Name)  when is_list(Name) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{status = enabled,
			 module = ?MODULE, type = counter}] ->
	    TS = exometer:timestamp(),
	    [ets:update_element(T, Name, [{#exometer_entry.value, 0},
					  {#exometer_entry.timestamp, TS}])
	     || T <- exometer:tables()],
	    ok;
	[#exometer_entry{status = enabled,
			 module = M, type = Type, ref = Ref}] ->
	    exometer_cache:delete(Name),
	    M:reset(Name, Type, Ref);
	[] ->
	    {error, not_found}
    end.


-spec setopts(name(), options()) -> ok | error().
setopts(Name, Options)  when is_list(Name), is_list(Options) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{status = enabled,
			 module = M, type = Type, ref = Ref} = E] ->
	    update_entry_elems(Name, [{#exometer_entry.options,
				       update_opts(
					 Options, E#exometer_entry.options)}]),
	    M:setopts(Name, Options, Type, Ref);
	[#exometer_entry{status = disabled, options = OldOpts,
			 module = M, type = Type, ref = Ref}] ->
	    case lists:keyfind(status, 1, Options) of
		{_, enabled} ->
		    update_entry_elems(Name, [{#exometer_entry.status, enabled},
					      {#exometer_entry.options,
					       update_opts(
						 Options, OldOpts)}]),
		    M:setopts(Name, Options, Type, Ref);
		false ->
		    {error, disabled}
	    end;
	[] ->
	    {error, not_found}
    end.

create_entry(#exometer_entry{module = ?MODULE, type = counter} = E, []) ->
    E1 = E#exometer_entry{value = 0},
    [ets:insert(T, E1) || T <- exometer:tables()],
    ok;
create_entry(#exometer_entry{module = M,
			     type = Type,
			     options = OptsTemplate,
			     name = Name} = E, Opts) ->
    %% Process local options before handing off the rest to M:new.
    E1 = process_opts(E, OptsTemplate ++ Opts),
    case Res = M:new(Name, Type, E1#exometer_entry.options) of
       ok ->
	    [ets:insert(T, E1) || T <- exometer:tables()];
	{ok, Ref} ->
	    [ets:insert(T, E1#exometer_entry{ ref = Ref })
	     || T <- exometer:tables()];
	_ ->
	    true
    end,
    Res.

cache(0, _, Value) ->
    Value;
cache(TTL, Name, Value) when TTL > 0 ->
    exometer_cache:write(Name, Value, TTL),
    Value.


update_entry_elems(Name, Elems) ->
    [ets:update_element(T, Name, Elems) || T <- exometer:tables()],
    ok.

info(Name, Item) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{} = E] ->
	    case Item of
		name      -> E#exometer_entry.name;
		type      -> E#exometer_entry.type;
		module    -> E#exometer_entry.module;
		value     -> get_value_(E);
		cache     -> E#exometer_entry.cache;
		status    -> E#exometer_entry.status;
		timestamp -> E#exometer_entry.timestamp;
		options   -> E#exometer_entry.options;
		ref       -> E#exometer_entry.ref;
		_ -> undefined
	    end;
	_ ->
	    undefined
    end.

info(Name) ->
    case ets:lookup(exometer:table(), Name) of
	[#exometer_entry{} = E] ->
	    Flds = record_info(fields, exometer_entry),
	    lists:keyreplace(value, 1,
			     lists:zip(Flds, tl(tuple_to_list(E))),
			     {value, get_value_(E)});
	_ ->
	    undefined
    end.

find_entries(Path) ->
    Pat = Path ++ '_',
    ets:select(?EXOMETER_TABLE,
	       [ { #exometer_entry{name = Pat, _ = '_'}, [],
		   [{{ {element, #exometer_entry.name, '$_'},
		       {element, #exometer_entry.type, '$_'},
		       {element, #exometer_entry.ref, '$_'} }}] } ]).

select(Pattern) ->
    ets:select(?EXOMETER_TABLE, [pattern(P) || P <- Pattern]).

select(Pattern, Limit) ->
    ets:select(?EXOMETER_TABLE, [pattern(P) || P <- Pattern], Limit).

pattern({'_', Gs, Prod}) ->
    {'_', repl(Gs, g_subst(['$_'])), repl(Prod, p_subst(['$_']))};
pattern({KP, Gs, Prod}) when is_atom(KP) ->
    {KP, repl(Gs, g_subst([KP,'$_'])), repl(Prod, p_subst([KP,'$_']))};
pattern({{N,T,R}, Gs, Prod}) ->
    {#exometer_entry{name = N, type = T, ref = R, _ = '_'},
     repl(Gs, g_subst(['$_'])), repl(Prod, p_subst(['$_']))}.

repl(P, Subst) when is_atom(P) ->
    case lists:keyfind(P, 1, Subst) of
	{_, Repl} -> Repl;
	false     -> P
    end;
repl(T, Subst) when is_tuple(T) ->
    list_to_tuple(repl(tuple_to_list(T), Subst));
repl([H|T], Subst) ->
    [repl(H, Subst)|repl(T, Subst)];
repl(X, _) ->
    X.

g_subst(Ks) ->
    [g_subst_(K) || K <- Ks].
g_subst_(K) when is_atom(K) ->
    {K, {{element,#exometer_entry.name,'$_'},
	 {element,#exometer_entry.type,'$_'},
	 {element,#exometer_entry.ref,'$_'}}}.

p_subst(Ks) ->
    [p_subst_(K) || K <- Ks].
p_subst_(K) when is_atom(K) ->
    {K, {{{element,#exometer_entry.name,'$_'},
	  {element,#exometer_entry.type,'$_'},
	  {element,#exometer_entry.ref,'$_'}}}}.


process_opts(Entry, Options) ->
    lists:foldl(
      fun
	  %% Some future  exometer_entry-level option
	  %% ({something, Val}, Entry1) ->
	  %%        Entry1#exometer_entry { something = Val };
	  %% Unknown option, pass on to exometer entry options list, replacing
	  %% any earlier versions of the same option.
	  ({cache, Val}, E) ->
	      if is_integer(Val), Val >= 0 ->
		      E#exometer_entry{cache = Val};
		 true ->
		      error({illegal, {cache, Val}})
	      end;
	  ({status, Status}, #exometer_entry{options = Os} = E) ->
	      if Status==enabled; Status==disabled ->
		      E#exometer_entry{status = Status,
				       options = lists:keystore(
						   status, 1, Os,
						   {status, Status})};
		 true ->
		      error({illegal, {status, Status}})
	      end;
	  ({Opt, Val}, #exometer_entry{options = Opts1} = Entry1) ->
	      Entry1#exometer_entry {
		options = [ {Opt, Val} | [O || {K,_} = O <- Opts1,
					       K =/= Opt] ] }
      end, Entry, Options).

update_opts(New, Old) ->
    lists:foldl(
      fun({K,_} = Opt, Acc) ->
	      lists:keystore(K, 1, Acc, Opt)
      end, Old, New).
