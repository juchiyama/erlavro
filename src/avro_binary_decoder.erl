%% coding: latin-1
%%% ============================================================================
%%% Copyright (c) 2016 Klarna AB
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%
%%% @doc
%%% Decode Avro values from binary format according to Avro 1.7.5
%%% specification.
%%%
%%% Schema is written following parsing canonical form recommendations
%%% but keeps all information (attributes are kept even if they are
%%% not relevant for parsing).
%%% @end
%%% ============================================================================

-module(avro_binary_decoder).

-export([ decode/3
        , decode/4
        , decode_stream/3
        , decode_stream/4
        ]).

-include("avro_internal.hrl").

-ifdef(TEST).
-export([zigzag/1]).
-endif.

-type hook() :: decoder_hook_fun().

%%%_* APIs =====================================================================

%% @doc decode/4 equivalent with default hook fun.
-spec decode(iodata(), string() | avro_type(),
             schema_store() | lkup_fun()) -> term().
decode(IoData, Type, StoreOrLkupFun) ->
  decode(IoData, Type, StoreOrLkupFun, ?DEFAULT_DECODER_HOOK).

%% @doc Decode bytes into unwrapped avro value, assuming the input bytes
%% matches the given schema without tailing bytes.
%% @end
-spec decode(iodata(), string() | avro_type(),
             schema_store() | lkup_fun(), hook()) -> term().
decode(IoData, Type, StoreOrLkupFun, Hook) ->
  %% return decoded value as raw erlang term directly
  {Value, <<>>} = do_decode(IoData, Type, StoreOrLkupFun, Hook),
  Value.

%% @doc decode_stream/4 equivalent with default hook fun.
-spec decode_stream(iodata(), string() | avro_type(),
                    schema_store() | lkup_fun()) -> term().
decode_stream(IoData, Type, StoreOrLkupFun) ->
  decode_stream(IoData, Type, StoreOrLkupFun, ?DEFAULT_DECODER_HOOK).

%% @doc Decode the header of a byte stream, return unwrapped value and tail
%% bytes in a tuple.
%% @end
-spec decode_stream(iodata(), string() | avro_type(),
                    schema_store() | lkup_fun(), hook()) -> term().
decode_stream(IoData, Type, StoreOrLkupFun, Hook) ->
  do_decode(IoData, Type, StoreOrLkupFun, Hook).


%%%_* Internal functions =======================================================

%% @private
do_decode(IoList, Type, Store, Hook) when not is_function(Store) ->
  Lkup = ?AVRO_SCHEMA_LOOKUP_FUN(Store),
  do_decode(IoList, Type, Lkup, Hook);
do_decode(IoList, Type, Lkup, Hook) when is_list(IoList) ->
  do_decode(iolist_to_binary(IoList), Type, Lkup, Hook);
do_decode(Bin, TypeName, Lkup, Hook) when ?IS_NAME(TypeName) ->
  do_decode(Bin, Lkup(TypeName), Lkup, Hook);
do_decode(Bin, Type, Lkup, Hook) when is_function(Hook, 4) ->
  dec(Bin, Type, Lkup, Hook).

%% @private
dec(Bin, T, _Lkup, Hook) when ?AVRO_IS_PRIMITIVE_TYPE(T) ->
  Hook(T, "", Bin, fun(B) -> prim(B, T#avro_primitive_type.name) end);
dec(Bin, T, Lkup, Hook) when ?AVRO_IS_RECORD_TYPE(T) ->
  Hook(T, none, Bin, fun(B) -> dec_record(B, T, Lkup, Hook) end);
dec(Bin, T, _Lkup, Hook) when ?AVRO_IS_ENUM_TYPE(T) ->
  {Index, Tail} = int(Bin),
  Hook(T, Index, Tail,
       fun(B) ->
         Symbol = avro_enum:get_symbol_from_index(T, Index),
         {Symbol, B}
       end);
dec(Bin, T, Lkup, Hook) when ?AVRO_IS_ARRAY_TYPE(T) ->
  ItemsType = avro_array:get_items_type(T),
  ItemDecodeFun =
    fun(Index, BinIn) ->
      Hook(T, Index, BinIn,
           fun(B) -> do_decode(B, ItemsType, Lkup, Hook) end)
    end,
  blocks(Bin, ItemDecodeFun);
dec(Bin, T, Lkup, Hook) when ?AVRO_IS_MAP_TYPE(T) ->
  ItemsType = avro_map:get_items_type(T),
  ItemDecodeFun =
    fun(_Index, BinIn) ->
      {Key, Tail1} = prim(BinIn, "string"),
      {Value, Tail} =
        Hook(T, Key, Tail1,
             fun(B) -> do_decode(B, ItemsType, Lkup, Hook) end),
      {{Key, Value}, Tail}
    end,
  blocks(Bin, ItemDecodeFun);
dec(Bin, T, Lkup, Hook) when ?AVRO_IS_UNION_TYPE(T) ->
  {Index, Tail} = long(Bin),
  case avro_union:lookup_child_type(T, Index) of
    {ok, ChildType} ->
      Hook(T, Index, Tail,
           fun(B) -> do_decode(B, ChildType, Lkup, Hook) end);
    false ->
      erlang:error({bad_union_index, T, Index})
  end;
dec(Bin, T, _Lkup, Hook) when ?AVRO_IS_FIXED_TYPE(T) ->
  Hook(T, "", Bin,
       fun(B) ->
          Size = avro_fixed:get_size(T),
          <<Value:Size/binary, Tail/binary>> = B,
          {Value, Tail}
       end).

%% @private
dec_record(Bin, T, Lkup, Hook) ->
  FieldTypes = avro_record:get_all_field_types(T),
  {FieldValuesReversed, Tail} =
    lists:foldl(
      fun({FieldName, FieldTypeOrName}, {Values, BinIn}) ->
        {Value, BinOut} =
          Hook(T, FieldName, BinIn,
               fun(B) -> do_decode(B, FieldTypeOrName, Lkup, Hook) end),
        {[{FieldName, Value} | Values], BinOut}
      end, {[], Bin}, FieldTypes),
  FieldValues = lists:reverse(FieldValuesReversed),
  {FieldValues, Tail}.

%% @private Decode primitive values.
%% NOTE: keep all binary decoding exceptions to error:{badmatch, _}
%%       to simplify higher level try catchs when detecting error
%% @end
prim(Bin, "null") ->
  {null, Bin};
prim(Bin, "boolean") ->
  <<Bool:8, Rest/binary>> = Bin,
  {Bool =:= 1, Rest};
prim(Bin, "int") ->
  int(Bin);
prim(Bin, "long") ->
  long(Bin);
prim(Bin, "float") ->
  <<Float:32/little-float, Rest/binary>> = Bin,
  {Float, Rest};
prim(Bin, "double") ->
  <<Float:64/little-float, Rest/binary>> = Bin,
  {Float, Rest};
prim(Bin, "bytes") ->
  bytes(Bin);
prim(Bin, "string") ->
  {Bytes, Tail} = bytes(Bin),
  {binary_to_list(Bytes), Tail}.

%% @private
bytes(Bin) ->
  {Size, Rest} = long(Bin),
  <<Bytes:Size/binary, Tail/binary>> = Rest,
  {Bytes, Tail}.

%% @private
blocks(Bin, ItemDecodeFun) ->
  blocks(Bin, ItemDecodeFun, _Index = 1, _Acc = []).

%% @private
blocks(Bin, ItemDecodeFun, Index, Acc) ->
  {Count0, Rest} = long(Bin),
  case Count0 =:= 0 of
    true ->
      %% a serial of blocks ends with 0
      {lists:reverse(Acc), Rest};
    false ->
      {Count, Tail0} =
        case Count0 < 0 of
          true ->
            %% block start with negative count number
            %% is followed by the block size in bytes
            %% here we simply discard the size info
            {_Size, Rest_} = long(Rest),
            {-Count0, Rest_};
          false ->
            {Count0, Rest}
        end,
      block(Tail0, ItemDecodeFun, Index, Acc, Count)
  end.

%% @private
block(Bin, ItemDecodeFun, Index, Acc, 0) ->
  blocks(Bin, ItemDecodeFun, Index, Acc);
block(Bin, ItemDecodeFun, Index, Acc, Count) ->
  {Item, Tail} = ItemDecodeFun(Index, Bin),
  block(Tail, ItemDecodeFun, Index+1, [Item | Acc], Count-1).

%% @private
int(Bin) -> zigzag(varint(Bin, 0, 0, 32)).

%% @private
long(Bin) -> zigzag(varint(Bin, 0, 0, 64)).

%% @private
zigzag({Int, TailBin}) -> {zigzag(Int), TailBin};
zigzag(Int)            -> (Int bsr 1) bxor -(Int band 1).

%% @private
varint(Bin, Acc, AccBits, MaxBits) ->
  <<Tag:1, Value:7, Tail/binary>> = Bin,
  true = (AccBits < MaxBits), %% assert
  NewAcc = (Value bsl AccBits) bor Acc,
  case Tag =:= 0 of
    true  -> {NewAcc, Tail};
    false -> varint(Tail, NewAcc, AccBits + 7, MaxBits)
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
