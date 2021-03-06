%%%-------------------------------------------------------------------
%%% Copyright (c) 2013-2016 Klarna AB
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
%%%-------------------------------------------------------------------
-module(erlavro_readme_tests).

-include("avro_internal.hrl").
-include_lib("eunit/include/eunit.hrl").

load_schmea_test() ->
  SchemaFilename = filename:join(priv_dir(), "interop.avsc"),
  OcfFilename = filename:join(priv_dir(), "interop.ocf"),
  Store = avro_schema_store:new([], [SchemaFilename]),
  Encoder = avro:make_encoder(Store, []),
  Decoder = avro:make_decoder(Store, []),
  Term = hd(element(3, avro_ocf:decode_file(OcfFilename))),
  Encoded = iolist_to_binary(Encoder("org.apache.avro.Interop", Term)),
  Term = Decoder("org.apache.avro.Interop", Encoded),
  ok.

binary_encode_decode_test() ->
  MyRecordType =
    avro_record:type(
      "MyRecord",
      [avro_record:define_field("f1", avro_primitive:int_type()),
       avro_record:define_field("f2", avro_primitive:string_type())],
      [{namespace, "com.example"}]),
  Store = avro_schema_store:add_type(MyRecordType, avro_schema_store:new([])),
  Encoder = avro:make_encoder(Store, []),
  Decoder = avro:make_decoder(Store, []),
  Term = [{"f1", 1}, {"f2", "my string"}],
  Bin = Encoder("com.example.MyRecord", Term),
  Term = Decoder("com.example.MyRecord", Bin),
  ok.

json_encode_decode_test() ->
  MyRecordType =
    avro_record:type(
      "MyRecord",
      [avro_record:define_field("f1", avro_primitive:int_type()),
       avro_record:define_field("f2", avro_primitive:string_type())],
      [{namespace, "com.example"}]),
  Store = avro_schema_store:add_type(MyRecordType, avro_schema_store:new([])),
  Encoder = avro:make_encoder(Store, [{encoding, avro_json}]),
  Decoder = avro:make_decoder(Store, [{encoding, avro_json}]),
  Term = [{"f1", 1}, {"f2", "my string"}],
  JSON = Encoder("com.example.MyRecord", Term),
  Term = Decoder("com.example.MyRecord", JSON),
  io:put_chars(user, JSON),
  ok.

encode_wrapped_test_() ->
  [ {"json encoder", fun() -> encode_wrapped([{encoding, avro_json}]) end}
  , {"binary encoder", fun() -> encode_wrapped([]) end}
  ].

encode_wrapped(CodecOptions) ->
  NullableInt = avro_union:type([avro_primitive:null_type(),
                                 avro_primitive:int_type()]),
  MyRecordType1 =
    avro_record:type(
      "MyRecord1",
      [avro_record:define_field("f1", NullableInt),
       avro_record:define_field("f2", avro_primitive:string_type())],
      [{namespace, "com.example"}]),
  MyRecordType2 =
    avro_record:type(
      "MyRecord2",
      [avro_record:define_field("f1", avro_primitive:string_type()),
       avro_record:define_field("f2", NullableInt)],
      [{namespace, "com.example"}]),
  MyUnion = avro_union:type([MyRecordType1, MyRecordType2]),
  MyArray = avro_array:type(MyUnion),
  Lkup = fun(_) -> erlang:error("not expecting type lookup because "
                                "all types are fully constructed. "
                                "i.e. no name references") end,
  %% Encode Records with type info wrapped
  %% so they can be used as a drop-in part of wrapper object
  WrappedEncoder = avro:make_encoder(Lkup, [wrapped | CodecOptions]),
  T1 = [{"f1", null}, {"f2", "str1"}],
  T2 = [{"f1", "str2"}, {"f2", 2}],
  %% Encode the records with type info wrapped
  R1 = WrappedEncoder(MyRecordType1, T1),
  R2 = WrappedEncoder(MyRecordType2, T2),
  %% Tag the union values for better encoding performance
  U1 = {"com.example.MyRecord1", R1},
  U2 = {"com.example.MyRecord2", R2},
  %% This encoder returns iodata result without type info wrapped
  BinaryEncoder = avro:make_encoder(Lkup, CodecOptions),
  %% Construct the array from encoded elements
  Bin = iolist_to_binary(BinaryEncoder(MyArray, [U1, U2])),
  %% Tag the decoded values
  Hook = avro_decoder_hooks:tag_unions(),
  Decoder = avro:make_decoder(Lkup, [{hook, Hook} | CodecOptions]),
  [ {"com.example.MyRecord1", [{"f1", null}, {"f2", "str1"}]}
  , {"com.example.MyRecord2", [{"f1", "str2"}, {"f2", 2}]}
  ] = Decoder(MyArray, Bin),
  ok.

%% @private
priv_dir() ->
  case code:priv_dir(erlavro) of
    {error, bad_name} ->
      %% application is not loaded, try dirty way
      case filelib:is_dir(filename:join(["..", priv])) of
        true -> filename:join(["..", priv]);
        _    -> "./priv"
      end;
    Dir ->
      Dir
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
