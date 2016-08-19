require 'test/unit'
require 'java'

$CLASSPATH << 'build/mirah-parser.jar'

class TestParsing < Test::Unit::TestCase
  java_import 'org.mirahparser.mmeta.SyntaxError'
  java_import 'org.mirahparser.mmeta.BaseParser'
  java_import 'mirahparser.impl.MirahParser'
  java_import 'mirahparser.lang.ast.NodeScanner'
  java_import 'mirahparser.lang.ast.Modifier'
  java_import 'mirahparser.lang.ast.StringCodeSource'
  java_import 'mirahparser.lang.ast.AnnotationList'

  class AstPrinter < NodeScanner
    def initialize
      @out = ""
      @first = true
    end
    def enterNullChild(obj)
      @out << ", null"
    end
    def enterDefault(node, arg)

      if node.kind_of?(AnnotationList) and node.size == 0
        # do not log empty annotations
        @first = false
        return false
      end

      @out << ", " unless @first
      @first = false
      if node.kind_of? Modifier
        @out << "[" << node.java_class.simple_name << ":" << node.value
      else
        @out << "[" << node.java_class.simple_name
      end
      true
    end

    def enterModifier(node, arg)
      @out << ", " unless @first
      @first = false
      @out << "[" << node.java_class.simple_name << ":" << node.value
      true
    end

    def exitDefault(node, arg)
      @first = false
      if node.kind_of?(AnnotationList) and node.size == 0
        # do not log empty annotations
      else
        @out << "]"
      end
    end
    %w(Boolean Fixnum Float CharLiteral SimpleString SimpleString).each do |name|
      eval(<<-EOF)
        def enter#{name}(node, arg)
          enterDefault(node, arg)
          @out << ", "
          @out << node.value.to_s
          true
        end
      EOF
    end
    def enterTypeRefImpl(node, arg)
      enterDefault(node, arg)
      @out << ", #{node.name}"
      @out << ", array" if node.isArray
      @out << ", static" if node.isStatic
      true
    end
    def enterNodeList(node, arg)
      @out << ", " unless @first
      @out << "["
      @first = true
      true
    end
    def enterBlockArgument(node, arg)
      enterDefault(node, arg)
      @out << ", optional" if node.optional
      true
    end
    def enterLoop(node, arg)
      enterDefault(node, arg)
      @out << ", skipFirstCheck" if node.skipFirstCheck
      @out << ", negative" if node.negative
      true
    end
    def exitFieldAccess(node, arg)
      @out << ", static" if node.isStatic
      exitDefault(node, arg)
    end
    alias exitFieldAssign exitFieldAccess
  end

  class PositionalAstPrinter < AstPrinter
    def enterDefault(node, arg)
      super
      @out << '(' << node.position.startLine.to_s << ":" << node.position.startColumn.to_s << ',' << node.position.endLine.to_s << ":" << node.position.endColumn.to_s << ')'
      true
    end
  end

  def parse(text, &block)
    @count ||= 0
    filename = "#{self.class.name}-#{@count += 1}"
    mirah_parser = MirahParser.new
    if @parser_options
        mirah_parser.instance_eval &@parser_options
    end
    # default base parser options
    BaseParser.module_eval do
      self.tracing = false
      self.debug_parse_tree = false
    end
    if @base_parser_options
      # custom base parser options
      BaseParser.module_eval &@base_parser_options
    end
    yield mirah_parser if block_given?
    result = mirah_parser.parse(StringCodeSource.new(filename, text))
    puts BaseParser.print_r(result) if BaseParser.tracing
    result
  end

  def assert_parse(expected, text)
    ast = parse(text)
    str = AstPrinter.new.scan(ast, ast)
    assert_equal(expected, str, "expected '#{text}' to be converted")
  end

  def assert_positional(expected, text)
    ast = parse(text)
    str = PositionalAstPrinter.new.scan(ast, ast)
    assert_equal(expected, str, "expected '#{text}' to be converted")
  end

  def parser_options &block
    @parser_options = block
  end

  def base_parser_options &block
    @base_parser_options = block
  end
  def with_options &block
    instance_eval &block
    @parser_options = nil
    @base_parser_options = nil
  end

  def assert_fails(text)
    begin
      fail("Should raise syntax error, but got #{parse text}")
    rescue SyntaxError
      # ok
    end
  end

  def test_fixnum
    assert_parse("[Script, [[Fixnum, 0]]]", '0')
    assert_parse("[Script, [[Fixnum, 100]]]", '1_0_0')
    assert_parse("[Script, [[Fixnum, 15]]]", '0xF')
    assert_parse("[Script, [[Fixnum, 15]]]", '0Xf')
    assert_parse("[Script, [[Fixnum, 15]]]", '017')
    assert_parse("[Script, [[Fixnum, 15]]]", '0o17')
    assert_parse("[Script, [[Fixnum, 15]]]", '0b1111')
    assert_parse("[Script, [[Fixnum, 15]]]", '0d15')
    assert_parse('[Script, [[Call, [Fixnum, 15], [SimpleString, -@], [], null]]]',
                 '-15')
    assert_parse("[Script, [[Fixnum, 2800088046]]]", '2800088046')
    assert_fails "0X"
    # assert_fails "0_"
    # assert_fails "0b1_"
    # assert_fails "0d_1"
  end

  def test_statements
    code = <<EOF
1
  2
        
3  


EOF
    assert_parse("[Script, [[Fixnum, 1], [Fixnum, 2], [Fixnum, 3]]]", code)
    assert_parse("[Script, [[Fixnum, 1], [Fixnum, 2]]]", "1; 2")
    ast = parse(code)
    assert_equal(1, ast.body.get(0).position.start_line)
    assert_equal(1, ast.body.get(0).position.start_column)
    assert_equal(1, ast.body.get(0).position.end_line)
    assert_equal(2, ast.body.get(0).position.end_column)
    assert_equal(2, ast.body.get(1).position.start_line)
    assert_equal(3, ast.body.get(1).position.start_column)
    assert_equal(2, ast.body.get(1).position.end_line)
    assert_equal(4, ast.body.get(1).position.end_column)
    assert_equal(4, ast.body.get(2).position.start_line)
    assert_equal(1, ast.body.get(2).position.start_column)
    assert_equal(4, ast.body.get(2).position.end_line)
    assert_equal(2, ast.body.get(2).position.end_column)
    assert_parse("[Script, []]", "# foo")
  end

  def test_position
    ast = parse("\n  foo  ").body.get(0)
    assert_equal("foo", ast.name.identifier)
    assert_equal(2, ast.position.start_line)
    assert_equal(3, ast.position.start_column)
    assert_equal(2, ast.position.end_line)
    assert_equal(6, ast.position.end_column)
    assert_equal("TestParsing-1", ast.position.source.name)
  end

  def test_position_after_multiline_sstring_literal
    ast = parse("SOMECONST = \'\n\n\n\'\n  foo  ").body.get(1)
    assert_equal("foo", ast.name.identifier)
    assert_equal(5, ast.position.start_line)
    assert_equal(3, ast.position.start_column)
    assert_equal(5, ast.position.end_line)
    assert_equal(6, ast.position.end_column)
    assert_equal("TestParsing-1", ast.position.source.name)
  end

  def test_position_after_multiline_dstring_literal
    ast = parse("SOMECONST = \"\n\n\n\"\n  foo  ").body.get(1)
    assert_equal("foo", ast.name.identifier)
    assert_equal(5, ast.position.start_line)
    assert_equal(3, ast.position.start_column)
    assert_equal(5, ast.position.end_line)
    assert_equal(6, ast.position.end_column)
    assert_equal("TestParsing-1", ast.position.source.name)
  end

  def test_modified_position
    ast = MirahParser.new.parse(
        StringCodeSource.new("test_modified_position", "foo", 3, 5)).body.get(0)
    assert_equal("foo", ast.name.identifier)
    assert_equal(3, ast.position.start_line)
    assert_equal(5, ast.position.start_column)
    assert_equal(3, ast.position.end_line)
    assert_equal(8, ast.position.end_column)
  end

  def test_symbol
    assert_parse("[Script, [[SimpleString, foo]]]", ':foo')
    assert_parse("[Script, [[SimpleString, bar]]]", ':bar')
    assert_parse("[Script, [[SimpleString, @bar]]]", ':@bar')
    assert_parse("[Script, [[SimpleString, @@cbar]]]", ':@@cbar')
    assert_fails(":")
  end

  def test_variable
    assert_parse("[Script, [[Boolean, true]]]", 'true')
    assert_parse("[Script, [[Boolean, false]]]", 'false')
    assert_parse("[Script, [[Null]]]", 'nil')
    assert_parse("[Script, [[Self]]]", 'self')
    assert_parse("[Script, [[FieldAccess, [SimpleString, foo]]]]", '@foo')
    assert_parse("[Script, [[FieldAccess, [SimpleString, bar]]]]", '@bar')
    assert_parse("[Script, [[FieldAccess, [SimpleString, cfoo], static]]]", '@@cfoo')
    assert_parse("[Script, [[FieldAccess, [SimpleString, cbar], static]]]", '@@cbar')
    assert_parse("[Script, [[VCall, [SimpleString, a]]]]", 'a')
    assert_parse("[Script, [[VCall, [SimpleString, b]]]]", 'b')
    assert_parse("[Script, [[VCall, [SimpleString, end_pos]]]]", 'end_pos')
    assert_parse("[Script, [[Constant, [SimpleString, A]]]]", 'A')
    assert_parse("[Script, [[Constant, [SimpleString, B]]]]", 'B')
    assert_parse("[Script, [[VCall, [SimpleString, B!]]]]", 'B!')
    assert_parse("[Script, [[VCall, [SimpleString, def?]]]]", 'def?')
    assert_fails("BEGIN")
    assert_fails("until")
    assert_fails("def!=")
  end

  def test_float
    assert_parse("[Script, [[Float, 1.0]]]", "1.0")
    assert_parse("[Script, [[Float, 0.0]]]", "0e1")
    assert_parse("[Script, [[Float, 10.0]]]", "1e0_1")
    assert_parse("[Script, [[Float, 320.0]]]", "3_2e0_1")
    assert_parse("[Script, [[Float, 422.2]]]", "4_2.2_2e0_1")
    assert_fails("1.")
  end

  def test_strings
    assert_parse("[Script, [[CharLiteral, 97]]]", "?a")
    assert_parse("[Script, [[CharLiteral, 65]]]", "?A")
    assert_parse("[Script, [[CharLiteral, 63]]]", "??")
    assert_parse("[Script, [[CharLiteral, 10]]]", "?\\n")
    assert_parse "[Script, [[CharLiteral, 92]]]", '?\\\\'
    assert_parse("[Script, [[CharLiteral, 32]]]", "?\\s")
    assert_parse("[Script, [[CharLiteral, 13]]]", "?\\r")
    assert_parse("[Script, [[CharLiteral, 9]]]", "?\\t")
    assert_parse("[Script, [[CharLiteral, 11]]]", "?\\v")
    assert_parse("[Script, [[CharLiteral, 12]]]", "?\\f")
    assert_parse("[Script, [[CharLiteral, 8]]]", "?\\b")
    assert_parse("[Script, [[CharLiteral, 7]]]", "?\\a")
    assert_parse("[Script, [[CharLiteral, 27]]]", "?\\e")
    assert_parse("[Script, [[CharLiteral, 10]]]", "?\\012")
    assert_parse("[Script, [[CharLiteral, 18]]]", "?\\x12")
    assert_parse("[Script, [[CharLiteral, 8364]]]", "?\\u20ac")
    assert_parse("[Script, [[CharLiteral, 119648]]]", "?\\U0001d360")
    assert_parse("[Script, [[CharLiteral, 91]]]", "?\\[")
    assert_fails("?aa")
    assert_parse("[Script, [[SimpleString, ]]]", "''")
    assert_parse("[Script, [[SimpleString, a]]]", "'a'")
    assert_parse("[Script, [[SimpleString, \\'\\n]]]", "'\\\\\\'\\n'")
    assert_fails("'")
    assert_fails("'\\'")
  end

  def test_squote_strings
    assert_parse("[Script, [[SimpleString, a'b]]]", "'a\\'b'")
  end

  def test_dquote_strings
    assert_parse("[Script, [[SimpleString, ]]]", '""')
    assert_parse("[Script, [[SimpleString, a]]]", '"a"')
    assert_parse("[Script, [[SimpleString, \"]]]", '"\\""')
    assert_parse("[Script, [[SimpleString, \\]]]", '"\\\\"')
    assert_parse(
      "[Script, [[StringConcat, [StringPieceList, [SimpleString, a ], [StringEval, [FieldAccess, [SimpleString, b]]], [SimpleString,  c]]]]]",
      '"a #@b c"')
    assert_parse(
      "[Script, [[StringConcat, [StringPieceList, [SimpleString, a ], [StringEval, [FieldAccess, [SimpleString, b], static]], [SimpleString,  c]]]]]",
      '"a #@@b c"')
    assert_parse(
      "[Script, [[StringConcat, [StringPieceList, [SimpleString, a], [StringEval, [[VCall, [SimpleString, b]]]], [SimpleString, c]]]]]",
      '"a#{b}c"')
    assert_parse(
      "[Script, [[StringConcat, [StringPieceList, [SimpleString, a], [StringEval, [[SimpleString, b]]], [SimpleString, c]]]]]",
      '"a#{"b"}c"')
    assert_parse(
      "[Script, [[StringConcat, [StringPieceList, [StringEval, []]]]]]",
      '"#{}"')
    assert_fails('"')
    assert_fails('"\"')
    assert_fails('"#@"')
    assert_fails('"#{"')
    assert_parse("[Script, [[SimpleString, \e[1m\e[31mERROR\e[0m: ]]]", '"\e[1m\e[31mERROR\e[0m: "')
  end

  def test_heredocs
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]]]]", "<<'A'\na\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, ]]]]]", "<<'A'\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n  A\n]]]]]", "<<'A'\na\n  A\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]]]]", "<<-'A'\na\n  A\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]], [StringConcat, [StringPieceList, [SimpleString, b\n]]], [Fixnum, 1]]]",
                 "<<'A';<<'A'\na\nA\nb\nA\n1")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, AA\n]]]]]", "<<A\nAA\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]]]]", "<<\"A\"\na\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n  A\n]]]]]", "<<A\na\n  A\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]]]]", "<<-A\na\n  A\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, ]]]]]", "<<A\nA\n")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [SimpleString, a\n]]], [StringConcat, [StringPieceList, [SimpleString, b\n]]], [Fixnum, 1]]]",
                 "<<A;<<A\na\nA\nb\nA\n1")
    assert_parse("[Script, [[StringConcat, [StringPieceList, [StringEval, [[StringConcat, [StringPieceList, [SimpleString, B\n]]]]], [SimpleString, \n]]], [StringConcat, [StringPieceList, [SimpleString, b\n]]], [Constant, [SimpleString, A]]]]",
                 "<<A;<<B\n\#{<<A\nB\nA\n}\nA\nb\nB\nA\n")
    assert_fails("<<FOO")
    assert_parse("[Script, [[FunctionalCall, [SimpleString, a], [[StringConcat, [StringPieceList, [SimpleString, c\n]]]], null]]]", "a <<b\nc\nb\n")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, <<], [[VCall, [SimpleString, b]]], null], [VCall, [SimpleString, c]], [VCall, [SimpleString, b]]]]", "a << b\nc\n b\n")
  end

  def test_regexp
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, a]], [SimpleString, ]]]]", '/a/')
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, \\/]], [SimpleString, ]]]]", '/\\//')
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, \\d(cow)+\\w\\\\]], [SimpleString, ]]]]", "/\\d(cow)+\\w\\\\/")
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, a]], [SimpleString, i]]]]", '/a/i')
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, a]], [SimpleString, iz]]]]", '/a/iz')
    assert_parse("[Script, [[Regex, [StringPieceList, [SimpleString, a], [StringEval, [[VCall, [SimpleString, b]]]], [SimpleString, c]], [SimpleString, iz]]]]", '/a#{b}c/iz')
    assert_parse("[Script, [[Regex, [StringPieceList], [SimpleString, ]]]]", '//')
  end

  def test_begin
    assert_parse("[Script, [[[Fixnum, 1], [Fixnum, 2]]]]", "begin; 1; 2; end")
    assert_parse("[Script, [[Fixnum, 1]]]", "begin; 1; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue; 2; end")
    assert_parse("[Script, [[Ensure, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[Fixnum, 2]]]], []]], [[Fixnum, 3]]]]]",
                 "begin; 1; rescue; 2; ensure 3; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue then 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[Fixnum, 2]]]], [[Fixnum, 3]]]]]",
                 "begin; 1; rescue then 2; else 3; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue;then 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], [SimpleString, ex], [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue => ex; 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList], [SimpleString, ex], [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue => ex then 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList, [Constant, [SimpleString, A]]], null, [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue A; 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]]], null, [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue A, B; 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]]], [SimpleString, t], [[Fixnum, 2]]]], []]]]",
                 "begin; 1; rescue A, B => t; 2; end")
    assert_parse("[Script, [[Rescue, [[Fixnum, 1]], [RescueClauseList, [RescueClause, [TypeNameList, [Constant, [SimpleString, A]]], [SimpleString, a], [[Fixnum, 2]]], [RescueClause, [TypeNameList, [Constant, [SimpleString, B]]], [SimpleString, b], [[Fixnum, 3]]]], []]]]",
                 "begin; 1; rescue A => a;2; rescue B => b; 3; end")
    assert_parse("[Script, [[[Fixnum, 1], [Fixnum, 2]]]]", "begin; 1; else; 2; end")
  end

  def test_primary
    assert_parse("[Script, [[[Boolean, true]]]]", '(true)')
    assert_parse("[Script, [[[Fixnum, 1], [Fixnum, 2]], [Fixnum, 3]]]", "(1; 2);3")
    assert_parse("[Script, [[Colon2, [Colon2, [Constant, [SimpleString, A]], [SimpleString, B]], [SimpleString, C]]]]", 'A::B::C')
    assert_parse("[Script, [[Colon2, [Colon2, [Colon3, [SimpleString, A]], [SimpleString, B]], [SimpleString, C]]]]", '::A::B::C')
    assert_parse("[Script, [[Array, []]]]", ' []')
    assert_parse("[Script, [[Array, [[Fixnum, 1], [Fixnum, 2]]]]]", ' [1 , 2 ]')
    assert_parse("[Script, [[Array, [[Fixnum, 1], [Fixnum, 2]]]]]", ' [1 , 2 , ]')
    assert_parse("[Script, [[Hash]]]", ' { }')
    assert_parse("[Script, [[Hash, [HashEntry, [Fixnum, 1], [Fixnum, 2]]]]]", ' { 1 => 2 }')
    assert_parse("[Script, [[Hash, [HashEntry, [Fixnum, 1], [Fixnum, 2]], [HashEntry, [Fixnum, 3], [Fixnum, 4]]]]]", ' { 1 => 2 , 3 => 4 }')
    assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a], [Fixnum, 2]]]]]", ' { a: 2 }')
    assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a], [Fixnum, 2]], [HashEntry, [SimpleString, b], [Fixnum, 4]]]]]", ' { a: 2 , b: 4 }')
    assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a], [Fixnum, 2]], [HashEntry, [SimpleString, b], [Fixnum, 4]]]]]", ' { "a"=> 2 , b: 4 }')
    assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a], [Fixnum, 2]], [HashEntry, [SimpleString, b], [Fixnum, 4]]]]]", ' { a: 2 , "b": 4 }')
    assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a b], [Fixnum, 2]], [HashEntry, [SimpleString, b], [Fixnum, 4]]]]]", ' { "a b": 2 , "b": 4 }')
    # assert_parse("[Script, [[Yield]]]", 'yield')
    # assert_parse("[Script, [[Yield]]]", 'yield ( )')
    # assert_parse("[Script, [[Yield, [Constant, [SimpleString, A]]]]]", 'yield(A)')
    # assert_parse("[Script, [[Yield, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]]]]]", 'yield (A , B)')
    # assert_parse("[Script, [[Yield, [Array, [[Constant, [SimpleString, A]], [Constant, [SimpleString, B]]]]]]]", 'yield([A , B])')
    assert_parse("[Script, [[Next]]]", 'next')
    assert_parse("[Script, [[Redo]]]", 'redo')
    assert_parse("[Script, [[Break]]]", 'break')
    # assert_parse("[Script, [[Retry]]]", 'retry')
    assert_parse("[Script, [[Not, []]]]", '!()')
    assert_parse("[Script, [[Not, [[Boolean, true]]]]]", '!(true)')
    assert_parse("[Script, [[ClassAppendSelf, [[Fixnum, 1]]]]]", 'class << self;1;end')
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], null, [[Fixnum, 1]], [TypeNameList], [ModifierList]]]]", 'class A;1;end')
    # assert_parse("[Script, [[ClassDefinition, [Colon2, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]]], [Fixnum, 1], [TypeNameList], [ModifierList]]]]", 'class A::B;1;end')
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]], [[Fixnum, 1]], [TypeNameList], [ModifierList]]]]", 'class A < B;1;end')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [], [Block, null, [[VCall, [SimpleString, x]]]]]]]", "foo do;x;end")
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [], [Block, null, [[VCall, [SimpleString, y]]]]]]]", "foo {y}")
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo?], [], [Block, null, [[VCall, [SimpleString, z]]]]]]]", "foo? {z}")
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, a]], null, [[Fixnum, 1]], [TypeNameList], [ModifierList]]]]", 'class a;1;end')
  end

  def test_modifiers
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], null, [], [TypeNameList], [AnnotationList, [Annotation, [Constant, [SimpleString, T]], [HashEntryList]]], [ModifierList, [Modifier:ABSTRACT]]]]]", "$T\nabstract class A;end")
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], null, [], [TypeNameList], [ModifierList, [Modifier:ABSTRACT]]]]]", "abstract class A;end")
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], null, [], [TypeNameList], [ModifierList, [Modifier:ABSTRACT], [Modifier:PRIVATE]]]]]", "abstract private class A;end")
    assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], null, [], [TypeNameList], [ModifierList, [Modifier:FINAL], [Modifier:ABSTRACT], [Modifier:PRIVATE]]]]]", "final abstract private class A;end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, +], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList, [Modifier:ABSTRACT]]]]]",
                 "abstract def +; 1; end")
    assert_parse("[Script, [[StaticMethodDefinition, [SimpleString, puts], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList, [Modifier:FINAL], [Modifier:PROTECTED]]]]]",
                 "final protected def self.puts; end")
    assert_parse("[Script, [[StaticMethodDefinition, [SimpleString, puts], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList, [Modifier:FINAL], [Modifier:SYNCHRONIZED]]]]]",
                 "final synchronized def self.puts; end")
    assert_parse("[Script, [[ConstantAssign, [SimpleString, A], [VCall, [SimpleString, b]], [ModifierList, [Modifier:FINAL]], null]]]",
                 "final A = b")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [VCall, [SimpleString, b]], [ModifierList, [Modifier:PROTECTED]], null]]]",
                 "protected @a = b")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [VCall, [SimpleString, b]], [ModifierList, [Modifier:FINAL], [Modifier:TRANSIENT]], null, static]]]",
                 "final transient @@a = b")
    assert_fails("abstract")
    assert_fails("def abstract;end")
    assert_fails("self.abstract")
  end

  def test_if
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Fixnum, 1]], []]]]",
                 'if a then 1 end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Fixnum, 1]], []]]]",
                 'if a;1;end')
    assert_positional("[Script(1:1,1:7), [[If(1:1,1:7), [VCall(1:6,1:7), [SimpleString(1:6,1:7), b]], [[VCall(1:1,1:2), [SimpleString(1:1,1:2), a]]], []]]]",
                      'a if b')
    assert_positional("[Script(1:1,1:37), [[FunctionalCall(1:1,1:37), [SimpleString(1:1,1:6), quote], [], [Block(1:7,1:37), null, [[If(1:9,1:36), [Call(1:23,1:36), [Unquote(1:23,1:28), [VCall(1:24,1:27), [SimpleString(1:24,1:27), bit]]], [SimpleString(1:29,1:36), hasNext], [], null], [[Call(1:9,1:19), [Unquote(1:9,1:14), [VCall(1:10,1:13), [SimpleString(1:10,1:13), bit]]], [SimpleString(1:15,1:19), next], [], null]], []]]]]]]",
                 'quote { `bit`.next if `bit`.hasNext}')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [], []]]]",
                 'if a;else;end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Fixnum, 1]], [[Fixnum, 2]]]]]",
                 'if a then 1 else 2 end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Fixnum, 1]], [[If, [VCall, [SimpleString, b]], [[Fixnum, 2]], [[Fixnum, 3]]]]]]]",
                 'if a; 1; elsif b; 2; else; 3; end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [], [[Fixnum, 1]]]]]",
                 'unless a then 1 end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [], [[Fixnum, 1]]]]]",
                 'unless a;1;end')
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Fixnum, 2]], [[Fixnum, 1]]]]]",
                 'unless a then 1 else 2 end')
    assert_fails("if;end")
    assert_fails("if a then 1 else 2 elsif b then 3 end")
    assert_fails("if a;elsif end")
  end

  def test_case
    # no case arg
    # single when no body
    assert_parse(
      "[Script, [[Case, null, [[WhenClause, [[VCall, [SimpleString, a]]], []]], []]]]",
      "case; when a; end")
    # single when body
    assert_parse(
      "[Script, [[Case, null, [[WhenClause, [[VCall, [SimpleString, a]]], [[VCall, [SimpleString, b]]]]], []]]]",
      "case; when a; b end")
    # multiple when
    assert_parse(
      "[Script, [[Case, null, " +
        "[[WhenClause, [[VCall, [SimpleString, a]]], [[VCall, [SimpleString, b]]]]," +
        " [WhenClause, [[VCall, [SimpleString, c]]], [[VCall, [SimpleString, d]]]]], []]]]",
      "case; when a; b; when c; d end")
    # multiple when args
    assert_parse(
      "[Script, [[Case, null, [[WhenClause, [[VCall, [SimpleString, a]], [VCall, [SimpleString, b]]], []]], []]]]",
      "case; when a, b; end")
    # multiple when args and body
    assert_parse(
      "[Script, [[Case, null, " +
        "[[WhenClause, [[VCall, [SimpleString, a]], [VCall, [SimpleString, b]]], [[VCall, [SimpleString, c]]]]], []]]]",
      "case; when a, b; c end")
    # when arg, else
    assert_parse(
      "[Script, [[Case, null, [[WhenClause, [[VCall, [SimpleString, a]]], []]], []]]]",
      "case; when a; else; end")
    # when arg, else, with body
    assert_parse(
      "[Script, [[Case, null, [[WhenClause, [[VCall, [SimpleString, a]]], []]], [[VCall, [SimpleString, b]]]]]]",
      "case; when a; else; b end")
    # case arg, when arg
    assert_parse(
      "[Script, [[Case, [VCall, [SimpleString, foo]], [[WhenClause, [[VCall, [SimpleString, a]]], []]], []]]]",
      "case foo; when a; end")

    # case arg nl when arg
    assert_parse(
      "[Script, [[Case, [VCall, [SimpleString, foo]], [[WhenClause, [[VCall, [SimpleString, a]]], []]], []]]]",
      "case foo
       when a; end")

    # assign from case
    assert_parse("[Script, [[LocalAssignment, [SimpleString, x], [Case, null, [[WhenClause, [[VCall, [SimpleString, a]]], [[VCall, [SimpleString, b]]]]], []], null]]]",
                 "x = case; when a; b; end")

    # when literal array
    assert_parse(
      "[Script, [[Case, [VCall, [SimpleString, foo]], [[WhenClause, [[Array, [[VCall, [SimpleString, a]]]]], []]], []]]]",
      "case foo; when [a]; end")

    # case;end
    # case; else
    # TODO assert error msgs
    assert_fails("case; end")
    # when no args
    assert_fails("case; when; end")
    # when no args; then
    assert_fails("case; when then end")
    # no when only else
    assert_fails("case; else; end")
    # when w/ args, when no args
    assert_fails("case; when a; when end")
    # case arg followed by non-when statement
    assert_fails("case; a; when a; when end")
  end

  def test_loop
    assert_parse("[Script, [[Loop, [], [Boolean, true], [], [], []]]]", 'while true do end')
    assert_parse("[Script, [[Loop, [], [VCall, [SimpleString, a]], [], [[VCall, [SimpleString, b]]], []]]]", 'while a do b end')
    assert_parse("[Script, [[Loop, [], [VCall, [SimpleString, a]], [], [[VCall, [SimpleString, b]]], []]]]", 'while a; b; end')
    assert_parse("[Script, [[Loop, negative, [], [Boolean, true], [], [], []]]]", 'until true do end')
    assert_parse("[Script, [[Loop, negative, [], [VCall, [SimpleString, a]], [], [[VCall, [SimpleString, b]]], []]]]", 'until a do b end')
    assert_parse("[Script, [[Loop, negative, [], [VCall, [SimpleString, a]], [], [[VCall, [SimpleString, b]]], []]]]", 'until a; b; end')
    assert_parse("[Script, [[Call, [Array, [[Fixnum, 1]]], [SimpleString, each], [], [Block, [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], [[Fixnum, 2]]]]]]", 'for a in [1];2;end')
  end

  def test_def
    names = %w(foo bar? baz! def= rescue Class & | ^ < > + - * / % ! ~ <=> ==
               === =~ !~ <= >= << >>> >> != ** []= [] +@ -@)
    names.each do |name|
      assert_parse("[Script, [[MethodDefinition, [SimpleString, #{name}], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                   "def #{name}; 1; end")
      assert_parse("[Script, [[StaticMethodDefinition, [SimpleString, #{name}], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                   "def self.#{name}; 1; end")
    end
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 2]], [ModifierList]]]]",
                 "def foo(a); 2; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo a; 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], [Constant, [SimpleString, String]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a:String); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], [Colon2, [Colon2, [Constant, [SimpleString, java]], [Constant, [SimpleString, lang]]], [Constant, [SimpleString, String]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a:java.lang.String); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], [Colon2, [Colon2, [Constant, [SimpleString, java]], [Constant, [SimpleString, lang]]], [Constant, [SimpleString, String]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a:java::lang::String); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null], [RequiredArgument, [SimpleString, b], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a, b); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, a], null, [Fixnum, 1]]], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a = 1); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, a], [Constant, [SimpleString, int]], [Fixnum, 1]]], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a:int = 1); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, a], null, [Fixnum, 1]], [OptionalArgument, [SimpleString, b], null, [Fixnum, 2]]], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a = 1, b=2); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, null, null], [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(*); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, [SimpleString, a], null], [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(*a); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, [SimpleString, a], [Constant, [SimpleString, Object]]], [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(*a:Object); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], [BlockArgument, [SimpleString, a], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(&a); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], [BlockArgument, optional, [SimpleString, a], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(&a = nil); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], [RestArgument, [SimpleString, c], null], [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a, b=1, *c, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], [RestArgument, [SimpleString, c], null], [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a, *c, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], null, [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a, b=1, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], [RestArgument, [SimpleString, c], null], [RequiredArgumentList], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a, b=1, *c, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], [RestArgument, [SimpleString, c], null], [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(b=1, *c, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], null, [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(b=1, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], null, [Fixnum, 1]]], [RestArgument, [SimpleString, c], null], [RequiredArgumentList], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(b=1, *c, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, [SimpleString, c], null], [RequiredArgumentList, [RequiredArgument, [SimpleString, d], null]], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(*c, d, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, [SimpleString, c], null], [RequiredArgumentList], [BlockArgument, [SimpleString, e], null]], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(*c, &e); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], [Constant, [SimpleString, int]], [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(a):int; 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, bar], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], [Constant, [SimpleString, int]], [[Fixnum, 1]], [ModifierList]]]]",
                 "def bar:int; 1; end")
    assert_fails("def foo(*a, *b);end")
    assert_fails("def foo(&a, &b);end")
    assert_fails("def foo(&a=1);end")
  end

  def test_method_call
    assert_parse("[Script, [[FunctionalCall, [SimpleString, B], [], null]]]", 'B()')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]]], null]]]", 'foo(a)')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]], [VCall, [SimpleString, b]]], null]]]", 'foo(a, b)')
    # assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]], [Splat, [VCall, [SimpleString, b]]]], null]]]", 'foo(a, *b)')
    # assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]], [Splat, [VCall, [SimpleString, b]]], [Hash, [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]]], null]]]", 'foo(a, *b, c:d)')
    # assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]], [Splat, [VCall, [SimpleString, b]]], [Hash, [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]]], null]]]", 'foo(a, *b, :c => d)')
    # assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, a]], [Splat, [VCall, [SimpleString, b]]], [Hash, [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]], [BlockPass, [VCall, [SimpleString, e]]]], null]]]", 'foo(a, *b, c:d, &e)')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[Hash, [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]]], null]]]", 'foo(c: d)')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[Hash, [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]], [BlockPass, [VCall, [SimpleString, e]]]], null]]]", 'foo(c: d, &e)')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [[BlockPass, [VCall, [SimpleString, e]]]], null]]]", 'foo(&e)')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, foo], [], null]]]", 'a.foo')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, foo], [], null]]]", 'a.foo()')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, Foo], [], null]]]", 'a.Foo()')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, <=>], [], null]]]", 'a.<=>')
    assert_parse("[Script, [[Call, [Constant, [SimpleString, Foo]], [SimpleString, Bar], [[VCall, [SimpleString, x]]], null]]]", 'Foo::Bar(x)')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [], null]]]", 'a.()')
    assert_parse("[Script, [[Call, [Constant, [SimpleString, System]], [SimpleString, in], [], null]]]", "System.in")
    assert_parse("[Script, [[Call, [Array, [[VCall, [SimpleString, la]], [VCall, [SimpleString, lb]]]], [SimpleString, each], [], null]]]", "[la, lb].each")
    assert_parse("[Script, [[Call, [Constant, [SimpleString, TreeNode]], [SimpleString, bottomUpTree], [[Call, [Fixnum, 2], [SimpleString, *], [[VCall, [SimpleString, item]]], null], [Call, [VCall, [SimpleString, depth]], [SimpleString, -], [[Fixnum, 1]], null]], null]]]", "TreeNode.bottomUpTree(2*item, depth - 1)")
    assert_parse("[Script, [[FunctionalCall, [SimpleString, iterate], [[Call, [VCall, [SimpleString, x]], [SimpleString, /], [[Float, 40.0]], null], [Call, [VCall, [SimpleString, y]], [SimpleString, /], [[Float, 40.0]], null]], null]]]", "iterate(x/40.0,y/40.0)")
    assert_parse("[Script, [[Super, [], null]]]", 'super()')
    assert_parse("[Script, [[ZSuper]]]", 'super')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, foo], [], null]]]", "a\n.\nfoo")
  end

  def test_command
    assert_parse("[Script, [[FunctionalCall, [SimpleString, A], [[VCall, [SimpleString, b]]], null]]]", 'A b')
    assert_parse("[Script, [[Call, [Constant, [SimpleString, Foo]], [SimpleString, Bar], [[VCall, [SimpleString, x]]], null]]]", 'Foo::Bar x')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, foo]], [SimpleString, bar], [[VCall, [SimpleString, x]]], null]]]", 'foo.bar x')
    assert_parse("[Script, [[Super, [[VCall, [SimpleString, x]]]]]]", 'super x')
    assert_parse("[Script, [[Yield, [[VCall, [SimpleString, x]]]]]]", 'yield x')
    assert_parse("[Script, [[Return, [VCall, [SimpleString, x]]]]]", 'return x')
    assert_parse("[Script, [[FunctionalCall, [SimpleString, a], [[CharLiteral, 97]], null]]]", 'a ?a')
    # assert_parse("[Script, [[FunctionalCall, [SimpleString, a], [[Splat, [VCall, [SimpleString, b]]]], null]]]", 'a *b')
  end

  def test_lhs
    assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [VCall, [SimpleString, b]], null]]]",
                 "a = b")
     assert_parse("[Script, [[ConstantAssign, [SimpleString, A], [VCall, [SimpleString, b]], [ModifierList], null]]]",
                 "A = b")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [VCall, [SimpleString, b]], [ModifierList], null]]]",
                 "@a = b")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [VCall, [SimpleString, b]], [ModifierList], null, static]]]",
                 "@@a = b")
    assert_parse("[Script, [[ElemAssign, [VCall, [SimpleString, a]], [[Fixnum, 0]], [VCall, [SimpleString, b]]]]]", "a[0] = b")
    assert_parse("[Script, [[AttrAssign, [VCall, [SimpleString, a]], [SimpleString, foo], [VCall, [SimpleString, b]]]]]", "a.foo = b")
    assert_parse("[Script, [[AttrAssign, [VCall, [SimpleString, a]], [SimpleString, foo], [VCall, [SimpleString, b]]]]]", "a::foo = b")
    assert_fails("a::Foo = b")
    assert_fails("::Foo = b")
  end

  def test_arg
assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [Rescue, [[VCall, [SimpleString, b]]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[VCall, [SimpleString, c]]]]], []], null]]]",
                 "a = b rescue c")
     assert_parse("[Script, [[If, [LocalAccess, [SimpleString, a]], [[LocalAssignment, [SimpleString, a], [VCall, [SimpleString, b]], null]], [[LocalAccess, [SimpleString, a]]]]]]",
                 "a &&= b")
     assert_parse("[Script, [[If, [LocalAccess, [SimpleString, a]], [[LocalAccess, [SimpleString, a]]], [[LocalAssignment, [SimpleString, a], [VCall, [SimpleString, b]], null]]]]]",
                 "a ||= b")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Call, [FieldAccess, [SimpleString, a]], [SimpleString, +], [[Fixnum, 1]], null], [ModifierList], null]]]",
                 "@a += 1")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [LocalAssignment, [SimpleString, $ptemp$2], [Fixnum, 1], null], [ElemAssign, [LocalAccess, [SimpleString, $ptemp$1]], [[LocalAccess, [SimpleString, $ptemp$2]]], [Call, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, []], [[LocalAccess, [SimpleString, $ptemp$2]]], null], [SimpleString, -], [[Fixnum, 2]], null]]]]]",
                 "a[1] -= 2")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [If, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [], null], [[AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [VCall, [SimpleString, b]]]], []]]]]",
                 "a.foo &&= b")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [[LocalAssignment, [SimpleString, $or$2], [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [], null], null], [If, [LocalAccess, [SimpleString, $or$2]], [[LocalAccess, [SimpleString, $or$2]]], [[AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [VCall, [SimpleString, b]]]]]]]]]",
                 "a::foo ||= b")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, Foo], [Call, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, Foo], [], null], [SimpleString, &], [[VCall, [SimpleString, b]]], null]]]]]",
                 "a.Foo &= b")
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[VCall, [SimpleString, b]]], [[VCall, [SimpleString, c]]]]]]",
                 "a ? b : c")
    # TODO operators need a ton more testing
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, +], [[VCall, [SimpleString, b]]], null]]]", "a + b")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, -], [[VCall, [SimpleString, b]]], null]]]", "a - b")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, *], [[VCall, [SimpleString, b]]], null]]]", "a * b")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, *], [[VCall, [SimpleString, b]]], null]]]", "a*b")
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, <], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], null]]]',
                 'a < -1')
    assert_parse('[Script, [[Call, [Fixnum, 1], [SimpleString, -@], [], null]]]',
                 '-1')
    assert_parse('[Script, [[Call, [Float, 1.0], [SimpleString, -@], [], null]]]',
                 '-1.0')
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, -@], [], null]]]", "-a")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, +@], [], null]]]", "+a")

    assert_parse("[Script, [[Call, [Call, [VCall, [SimpleString, a]], [SimpleString, -], [[VCall, [SimpleString, b]]], null], [SimpleString, +], [[VCall, [SimpleString, c]]], null]]]",
                 "a - b + c")

    assert_fails("::A ||= 1")
    assert_fails("A::B ||= 1")
   end

   def test_expr
     assert_parse("[Script, [[If, [LocalAssignment, [SimpleString, a], [Fixnum, 1], null], [[LocalAssignment, [SimpleString, b], [Fixnum, 2], null]], []]]]",
                 "a = 1 and b = 2")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $or$1], [LocalAssignment, [SimpleString, a], [Fixnum, 1], null], null], [If, [LocalAccess, [SimpleString, $or$1]], [[LocalAccess, [SimpleString, $or$1]]], [[LocalAssignment, [SimpleString, b], [Fixnum, 2], null]]]]]]",
                 "a = 1 or b = 2")
     assert_parse("[Script, [[Not, [LocalAssignment, [SimpleString, a], [Fixnum, 1], null]]]]",
                 "not a = 1")
    assert_parse("[Script, [[Not, [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]]]]",
                 "! foo bar")
    assert_parse("[Script, [[If, [VCall, [SimpleString, a]], [[Call, [VCall, [SimpleString, x]], [SimpleString, children], [], null]], [[Array, [[VCall, [SimpleString, x]]]]]]]]", "a ? x.children : [x]")
   end

   def test_stmt
    assert_parse("[Script, [[If, [VCall, [SimpleString, b]], [[VCall, [SimpleString, a]]], []]]]", "a if b")
    assert_parse("[Script, [[If, [VCall, [SimpleString, b]], [], [[VCall, [SimpleString, a]]]]]]", "a unless b")
    assert_parse("[Script, [[Loop, [], [VCall, [SimpleString, b]], [], [[VCall, [SimpleString, a]]], []]]]", "a while b")
    assert_parse("[Script, [[Loop, negative, [], [VCall, [SimpleString, b]], [], [[VCall, [SimpleString, a]]], []]]]", "a until b")
    assert_parse("[Script, [[Loop, skipFirstCheck, [], [VCall, [SimpleString, b]], [], [[VCall, [SimpleString, a]]], []]]]", "begin;a;end while b")
    assert_parse("[Script, [[Loop, skipFirstCheck, negative, [], [VCall, [SimpleString, b]], [], [[VCall, [SimpleString, a]]], []]]]", "begin;a;end until b")
    assert_parse("[Script, [[Rescue, [[VCall, [SimpleString, a]]], [RescueClauseList, [RescueClause, [TypeNameList], null, [[VCall, [SimpleString, b]]]]], []]]]",
                 "a rescue b")
     assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null], null]]]",
                 "a = foo bar")
     assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [Call, [LocalAccess, [SimpleString, a]], [SimpleString, +], [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]], null], null]]]",
                 "a += foo bar")
     assert_parse("[Script, [[If, [LocalAccess, [SimpleString, a]], [[LocalAssignment, [SimpleString, a], [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null], null]], [[LocalAccess, [SimpleString, a]]]]]]",
                 "a &&= foo bar")
     assert_parse("[Script, [[If, [LocalAccess, [SimpleString, a]], [[LocalAccess, [SimpleString, a]]], [[LocalAssignment, [SimpleString, a], [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null], null]]]]]",
                 "a ||= foo bar")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [LocalAssignment, [SimpleString, $ptemp$2], [Fixnum, 1], null], [ElemAssign, [LocalAccess, [SimpleString, $ptemp$1]], [[LocalAccess, [SimpleString, $ptemp$2]]], [Call, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, []], [[LocalAccess, [SimpleString, $ptemp$2]]], null], [SimpleString, -], [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]], null]]]]]",
                 "a[1] -= foo bar")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [If, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [], null], [[AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]]], []]]]]",
                 "a.foo &&= foo bar")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [[LocalAssignment, [SimpleString, $or$2], [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [], null], null], [If, [LocalAccess, [SimpleString, $or$2]], [[LocalAccess, [SimpleString, $or$2]]], [[AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, foo], [FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]]]]]]]]",
                 "a::foo ||= foo bar")
     assert_parse("[Script, [[[LocalAssignment, [SimpleString, $ptemp$1], [VCall, [SimpleString, a]], null], [AttrAssign, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, Foo], [Call, [Call, [LocalAccess, [SimpleString, $ptemp$1]], [SimpleString, Foo], [], null], [SimpleString, &], [[FunctionalCall, [SimpleString, foo], [[VCall, [SimpleString, bar]]], null]], null]]]]]",
                 "a.Foo &= foo bar")
    assert_parse("[Script, [[If, [Boolean, true], [[Return, [ImplicitNil]]], []]]]", "return if true")
   end

   def test_block_args
     assert_parse("[Script, [[FunctionalCall, [SimpleString, a], [], [Block, [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, x], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], [[VCall, [SimpleString, x]]]]]]]", "a {|x| x}")
     assert_parse("[Script, [[FunctionalCall, [SimpleString, a], [], [Block, [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], [[VCall, [SimpleString, x]]]]]]]", "a {|| x}")
   end

   def test_block_call
     assert_parse("[Script, [[Call, [FunctionalCall, [SimpleString, a], [], [Block, null, [[VCall, [SimpleString, b]]]]], [SimpleString, c], [], null]]]", "a do;b;end.c")
     assert_parse("[Script, [[Call, [FunctionalCall, [SimpleString, a], [], [Block, null, [[VCall, [SimpleString, b]]]]], [SimpleString, c], [], null]]]", "a {b}.c")
     assert_parse("[Script, [[Super, [[VCall, [SimpleString, a]]], [Block, null, [[VCall, [SimpleString, b]]]]]]]", "super a do;b;end")
     assert_parse("[Script, [[Super, [[Call, [FunctionalCall, [SimpleString, a], [], [Block, null, [[VCall, [SimpleString, b]]]]], [SimpleString, c], [], null]], null]]]", "super a {b}.c")
     assert_parse("[Script, [[Call, [Super, [[VCall, [SimpleString, a]]], [Block, null, [[VCall, [SimpleString, b]]]]], [SimpleString, c], [], null]]]", "super a do;b;end.c")
     assert_parse("[Script, [[FunctionalCall, [SimpleString, do_call], [[FunctionalCall, [SimpleString, curly_call], [], [Block, null, [[VCall, [SimpleString, curlyblock]]]]]], [Block, null, [[VCall, [SimpleString, doblock]]]]]]]",
                  "do_call curly_call {curlyblock} do;doblock;end")
     assert_parse("[Script, [[FunctionalCall, [SimpleString, a_call], [[FunctionalCall, [SimpleString, an_arg], [], [Block, null, [[VCall, [SimpleString, curlyblock]]]]]], null]]]",
                  "a_call an_arg { curlyblock }")
     assert_parse("[Script, [[FunctionalCall, [SimpleString, a_call], [[VCall, [SimpleString, an_arg]]], [Block, null, [[VCall, [SimpleString, do_block]]]]]]]",
                  "a_call an_arg do; do_block; end")
     assert_parse("[Script, [[Call, [Constant, [SimpleString, A]], [SimpleString, call], [[FunctionalCall, [SimpleString, an_arg], [], [Block, null, [[VCall, [SimpleString, curlyblock]]]]]], null]]]",
                  "A.call an_arg {curlyblock}")
     # assert_parse("[Script, [[Call, [Constant, [SimpleString, A]], [SimpleString, call], [[VCall, [SimpleString, an_arg]]], [Block, null, [[VCall, [SimpleString, do_block]]]]]], null]]]",
     #              "A.call an_arg do; do_block; end")
   end

   def test_opt_nl
     assert_parse("[Script, [[Hash, [HashEntry, [SimpleString, a], [SimpleString, b]], [HashEntry, [SimpleString, c], [VCall, [SimpleString, d]]]]]]",
                  "{\n'a' => 'b', c:\nd\n}")
   end

   def test_ne_op
     assert_parse("[Script, [[Call, [VCall, [SimpleString, foo]], [SimpleString, !=], [[VCall, [SimpleString, bar]]], null]]]", "foo!=bar")
   end

   def test_nee_op
     assert_parse("[Script, [[Call, [VCall, [SimpleString, foo]], [SimpleString, !==], [[VCall, [SimpleString, bar]]], null]]]", "foo!==bar")
   end

   def test_command
     assert_parse("[Script, [[]]]", "begin  # hi\nend")
   end

   def test_macros
     assert_parse("[Script, [[Unquote, [VCall, [SimpleString, x]]]]]", '`x`')
     assert_parse("[Script, [[ClassDefinition, [Unquote, [Constant, [SimpleString, A]]], null, [[Fixnum, 1]], [TypeNameList], [ModifierList]]]]", 'class `A`;1;end')
     assert_parse("[Script, [[MethodDefinition, [Unquote, [VCall, [SimpleString, foo]]], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                  "def `foo`(a); 1; end")
    assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [Unquote, [VCall, [SimpleString, a]]], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                 "def foo(`a`); 1; end")
    assert_parse("[Script, [[Call, [VCall, [SimpleString, a]], [Unquote, [VCall, [SimpleString, foo]]], [], null]]]", 'a.`foo`')
    assert_parse("[Script, [[Call, [Self], [Unquote, [VCall, [SimpleString, foo]]], [], null]]]", 'self.`foo`')
    assert_parse("[Script, [[FieldAccess, [Unquote, [VCall, [SimpleString, a]]]]]]", "@`a`")
     assert_parse("[Script, [[FieldAssign, [Unquote, [VCall, [SimpleString, a]]], [Fixnum, 1], [ModifierList], null]]]",
                  "@`a` = 1")
    assert_parse("[Script, [[UnquoteAssign, [Unquote, [VCall, [SimpleString, a]]], [VCall, [SimpleString, b]]]]]", "`a` = b")
    assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null," +
                                               " [[FunctionalCall, [SimpleString, quote], [], [Block, null, [[VCall, [SimpleString, bar]]]]]]]]]",
                 "macro def foo; quote {bar}; end")
    assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null," +
                                               " [[FunctionalCall, [SimpleString, quote], [], [Block, null, [[VCall, [SimpleString, bar]]]]]]]]]",
                 "macro def foo; quote do bar end; end")
    assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null," +
                                               " [[VCall, [SimpleString, bar]]," +
                                                      " [FunctionalCall, [SimpleString, quote], [], [Block, null, [[VCall, [SimpleString, baz]]]]]]]]]",
                 "macro def foo; bar; quote do baz end; end")
   end

   def test_annotation
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList]]], [ModifierList], null]]]", "$Foo @a = 1")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList, [HashEntry, [SimpleString, value], [Constant, [SimpleString, Bar]]]]]], [ModifierList], null]]]", "$Foo[Bar] @a = 1")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList, [HashEntry, [SimpleString, foo], [Constant, [SimpleString, Bar]]]]]], [ModifierList], null]]]", "$Foo[foo: Bar] @a = 1")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Colon2, [Constant, [SimpleString, foo]], [Constant, [SimpleString, Bar]]], [HashEntryList]]], [ModifierList], null]]]", "$foo.Bar @a = 1")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Colon2, [Constant, [SimpleString, foo]], [Constant, [SimpleString, Bar]]], [HashEntryList]]], [ModifierList], null]]]", "$foo::Bar @a = 1")
     assert_parse("[Script, [[FieldAssign, [SimpleString, a], [Fixnum, 1], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList, [HashEntry, [SimpleString, value], [Array, [[Constant, [SimpleString, Bar]], [Constant, [SimpleString, Baz]]]]]]]], [ModifierList], null]]]", "$Foo[Bar, Baz] @a = 1")
   end

  def test_param_annotation
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], [Constant, [SimpleString, int]], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                 'def method($Foo a:int);end')
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null, [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList, [HashEntry, [SimpleString, value], [Array, [[Constant, [SimpleString, Bar]], [Constant, [SimpleString, Baz]]]]]]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                 'def method($Foo[Bar, Baz] a);end')
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null], [RequiredArgument, [SimpleString, b], [Constant, [SimpleString, int]], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList, [HashEntry, [SimpleString, foo], [Constant, [SimpleString, Bar]]]]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                 'def method(a, $Foo[foo: Bar] b:int);end')
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null], [RequiredArgument, [SimpleString, b], [Constant, [SimpleString, int]], [AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], [Constant, [SimpleString, void]], [], [ModifierList]]]]',
                 'def method(a, $Foo b:int):void;end')
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList], [OptionalArgumentList], [RestArgument, [SimpleString, a], [Constant, [SimpleString, int]], [AnnotationList, [Annotation, [Colon2, [Constant, [SimpleString, foo]], [Constant, [SimpleString, Bar]]], [HashEntryList]]]], [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                 'def method($foo.Bar *a:int);end')
    assert_parse('[Script, [[MethodDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null, [AnnotationList, [Annotation, [Constant, [SimpleString, Bar]], [HashEntryList]]]]], [OptionalArgumentList, [OptionalArgument, [SimpleString, b], [Constant, [SimpleString, int]], [Fixnum, 0], [AnnotationList, [Annotation, [Constant, [SimpleString, Baz]], [HashEntryList]]]]], null, [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                 'def method($Bar a, $Baz b:int = 0);end')
    assert_parse('[Script, [[MacroDefinition, [SimpleString, method], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null, [AnnotationList, [Annotation, [Colon2, [Constant, [SimpleString, foo]], [Constant, [SimpleString, Bar]]], [HashEntryList]]]]], [OptionalArgumentList], null, [RequiredArgumentList], null], []]]]',
                 'macro def method($foo::Bar a);end')
  end

  def test_return
     assert_parse('[Script, [[Return, [Call, [Fixnum, 1], [SimpleString, -@], [], null]]]]',
                  'return -1')
     assert_parse('[Script, [[Return, [[Call, [Fixnum, 1], [SimpleString, -@], [], null]]]]]',
                  'return (-1)')
     assert_parse("[Script, [[Return, [ImplicitNil]]]]", "return")
   end

   def test_call_assocs
    assert_parse("[Script, [[FunctionalCall, [SimpleString, puts], [[Hash, [HashEntry, [SimpleString, a], [SimpleString, b]]]], null]]]", "puts :a => :b")
   end

   def test_block_comment
     assert_parse("[Script, [[Fixnum, 3]]]", "/* A /* nested */ comment */3")
   end

   def test_assign_nl
     assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [Fixnum, 1], null]]]", "a =\n   1")
     assert_parse("[Script, [[LocalAssignment, [SimpleString, html], [Call, [LocalAccess, [SimpleString, html]], [SimpleString, +], [[SimpleString, ]], null], null]]]", " html += \n ''")
   end

   def test_parent
     script = parse('if a then b else c end')
     assert_equal(script, script.body.parent)
     if_node = script.body.get(0)
     assert_equal(if_node, if_node.condition.parent)
     assert_equal(if_node, if_node.body.parent)
     assert_equal(if_node, if_node.elseBody.parent)
   end

   def test_enddef
     assert_parse("[Script, [[If, [Fixnum, 1], [[Fixnum, 2]], []], [MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                  "if 1 then 2; end
                  def foo; 1; end")
   end

   def test_array_type
     assert_parse("[Script, [[MethodDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], [TypeRefImpl, String, array]]], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [[Fixnum, 1]], [ModifierList]]]]",
                  "def foo(a:String[]); 1; end")
   end

   def test_interface
     assert_parse("[Script, [[InterfaceDeclaration, " +
                             "[Constant, [SimpleString, A]], null, " +
                             "[[Fixnum, 1]], " +
                             "[TypeNameList], [ModifierList]]]]",
                  "interface A;1;end")
     assert_parse("[Script, [[InterfaceDeclaration, " +
                             "[Constant, [SimpleString, A]], null, " +
                             "[[Fixnum, 1]], " +
                             "[TypeNameList, [Constant, [SimpleString, B]], [Constant, [SimpleString, C]]], [ModifierList]]]]",
                  "interface A < B, C do 1;end")
     assert_parse("[Script, [[InterfaceDeclaration, " +
                             "[Constant, [SimpleString, A]], null, [], " +
                             "[TypeNameList], " +
                             "[AnnotationList, [Annotation, [Constant, [SimpleString, Foo]], [HashEntryList]]], [ModifierList]]]]",
                  "$Foo interface A; end")
   end

   def test_raise
     assert_parse("[Script, [[Raise, []]]]", 'raise')
     assert_parse("[Script, [[Raise, [[Fixnum, 1]]]]]", 'raise 1')
     assert_parse("[Script, [[Raise, [[Fixnum, 1], [Fixnum, 2]]]]]", 'raise(1, 2)')
   end

   def test_import
     assert_parse("[Script, [[Import, [SimpleString, java.util.ArrayList], [SimpleString, ArrayList]]]]", 'import java.util.ArrayList')

     assert_parse("[Script, [[Import, [SimpleString, java.util.Arrays.asList], [SimpleString, .asList]]]]", 'import static java.util.Arrays.asList')
     assert_parse("[Script, [[Import, [SimpleString, java.util.Arrays], [SimpleString, .*]]]]", 'import static java.util.Arrays.*')

     assert_parse("[Script, [[Import, [SimpleString, java.util.ArrayList], [SimpleString, AL]]]]", 'import java.util.ArrayList as AL')
     assert_parse("[Script, [[Import, [SimpleString, java.util], [SimpleString, *]]]]", 'import java.util.*')
     assert_parse("[Script, [[Import, [SimpleString, java.util.ArrayList], [SimpleString, ArrayList]]]]", "import 'java.util.ArrayList'")
     assert_parse("[Script, [[Import, [SimpleString, java.util.ArrayList], [SimpleString, AL]]]]", 'import "AL", "java.util.ArrayList"')
   end

   def test_package
     assert_parse("[Script, [[Package, [SimpleString, foo], null]]]", 'package foo')
     assert_parse("[Script, [[Package, [SimpleString, bar], [[Fixnum, 1]]]]]", 'package bar { 1 }')
   end

   def test_macro
     assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null, [[Fixnum, 1]]]]]",
                  "defmacro foo; 1; end")
     # assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null, [[Fixnum, 1]]]]]",
     #              "defmacro foo do; 1; end")
     assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], null, [[Fixnum, 1]]]]]",
                  "macro def foo; 1; end")
     assert_parse("[Script, [[MacroDefinition, [SimpleString, foo], [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], [[Fixnum, 2]]]]]",
                  "macro def foo(a); 2; end")
   end
   
   def test_clone_arguments
     ast1 = parse("def foo(bar); end")
     ast2 = parse("def baz; end")
     method1 = ast1.body(0)
     method2 = ast2.body(0)
     assert_equal(1, method1.arguments.required_size)
     assert_equal(0, method2.arguments.required_size)

     method2.arguments_set(method1.arguments.clone)
     assert_equal(1, method1.arguments.required_size)
     assert_equal(1, method2.arguments.required_size)

     method2.arguments.required.remove(0)
     assert_equal(1, method1.arguments.required_size)
     assert_equal(0, method2.arguments.required_size)
   end
   
   def test_replaceChild
     ast1 = parse("`foo`")
     ast2 = parse("bar")
     unquote = ast1.body(0)
     call = ast2.body(0)
     assert_equal ast1.body, unquote.parent
     assert_equal ast2.body, call.parent
     
     new_call = ast1.body.replaceChild(unquote, call)
     
     assert_equal new_call, ast1.body(0)
     assert_nil unquote.parent
     assert_not_equal new_call, call
     assert_equal new_call.toString, call.toString
     assert_equal ast1.body, new_call.parent
     assert_equal ast2.body, call.parent
   end
   
   def test_unquote_stringconcat
     ast = parse('def foo `"#{bar}"`;end')
   end
   
   def test_while_position
     ast = parse('while true do 1 end')
     assert_not_nil ast.body().position
   end
   
   def test_do_block_position
     ast = parse("quote do\na\nend")
     block_pos = ast.body(0).block.body.position
     contents = block_pos.source.substring(block_pos.startChar, block_pos.endChar)
     assert_match(/^\s*a\s*$/, contents)
   end

   def test_brace_block_position
     ast = parse("quote {a}")
     block_pos = ast.body(0).block.body.position
     contents = block_pos.source.substring(block_pos.startChar, block_pos.endChar)
     assert_match(/^\s*a\s*$/, contents)
   end
   
   def test_unquote_arguments
     ast = parse("`'foo'`")
     unquote = ast.body(0)
     unquote.object_set(unquote.value)
     args = unquote.arguments
     assert_equal('foo', args.required(0).name.identifier)
   end

   def test_implements
     assert_parse("[Script, [[ClassDefinition, [Constant, [SimpleString, A]], [Constant, [SimpleString, B]], [[Fixnum, 1]], [TypeNameList, [Constant, [SimpleString, Bar]]], [ModifierList]]]]",
                  "class A < B\n#foo\nimplements Bar;1;end")
   end

   class CheckParents < NodeScanner
     def initialize(test, print=false)
       super()
       @test = test
       @print = false
       @indent = 0
     end
     def enterDefault(node, arg)
       if node == arg
         puts "#{" "*@indent}#{node} (#{id(node)}, parent = #{id(node.parent)})" if @print
         @indent += 2
         true
       else
         scan(node, node)
         @test.assert_equal(arg, node.parent, node.inspect) 
         false
       end
     end
     def exitDefault(node, arg)
       @indent -= 2 if node == arg
     end
     def id(obj)
       return 'nil' if obj.nil?
       inspected = obj.inspect
       if inspected =~ /:(0x[a-f0-9]+)/
         $1
       else
         obj.object_id
       end
     end
   end
   
   def test_clone_parents
     ast = parse(<<-EOF)
       quote do
         `map` = java::util::HashMap.new(`Fixnum.new(capacity)`)
         `map`.put(a, b)
         map.put(a, b)
         nil
       end
     EOF
     checker = CheckParents.new(self)
     checker.scan(ast, ast)

     ast2 = ast.clone
     checker.scan(ast2, ast2)
     checker.scan(ast, ast)
     
     ast3 = ast.body(0).block.body.clone
     checker.scan(ast, ast)
     checker.scan(ast2, ast2)
     checker.scan(ast3, ast3)
     assert_nil(ast3.parent)
   end

  def test_unclosed_double_quote_is_error
    assert_fails "\"no closing quote"
    assert_fails "\""
    assert_fails "\"\n"
  end

  def test_unclosed_single_quote_is_error
    assert_fails "'no closing quote"
    assert_fails "'"
    assert_fails "'\n"
  end

  def test_double_quote_string_with_just_two_octothorpes
    assert_parse "[Script, [[FunctionalCall, [SimpleString, puts], [[SimpleString, ##]], null]]]",
    'puts "##"'
  end

  def test_block_with_not_pipes
    assert_parse("[Script, [[FunctionalCall, [SimpleString, foo], [], [Block, [Arguments, [RequiredArgumentList, [RequiredArgument, [SimpleString, a], null]], [OptionalArgumentList], null, [RequiredArgumentList], null], [[[LocalAssignment, [SimpleString, $or$1], [Not, [VCall, [SimpleString, a]]], null], [If, [LocalAccess, [SimpleString, $or$1]], [[LocalAccess, [SimpleString, $or$1]]], [[VCall, [SimpleString, a]]]]]]]]]]",
                 "foo {|a| !a || a }")
  end

  def test_not_pipes
    assert_parse("[Script, [[[LocalAssignment, [SimpleString, $or$1], [Not, [VCall, [SimpleString, a]]], null], [If, [LocalAccess, [SimpleString, $or$1]], [[LocalAccess, [SimpleString, $or$1]]], [[VCall, [SimpleString, a]]]]]]]",
                 "!a || a")
  end

  def test_not_ampers
    assert_parse "[Script, [[If, [Not, [VCall, [SimpleString, a]]], [[VCall, [SimpleString, a]]], []]]]",
     '!a && a'
  end

  def test_not_pipes_and_pipes
    assert_parse("[Script, [[If, [[LocalAssignment, [SimpleString, $or$1], [VCall, [SimpleString, a]], null], [If, [LocalAccess, [SimpleString, $or$1]], [[LocalAccess, [SimpleString, $or$1]]], [[VCall, [SimpleString, a]]]]], [[[LocalAssignment, [SimpleString, $or$2], [VCall, [SimpleString, a]], null], [If, [LocalAccess, [SimpleString, $or$2]], [[LocalAccess, [SimpleString, $or$2]]], [[VCall, [SimpleString, a]]]]]], []]]]",
                 "a || a and a || a")
  end

  def test_assign_not_pipes
    assert_parse("[Script, [[LocalAssignment, [SimpleString, a], [[LocalAssignment, [SimpleString, $or$1], [Not, [VCall, [SimpleString, a]]], null], [If, [LocalAccess, [SimpleString, $or$1]], [[LocalAccess, [SimpleString, $or$1]]], [[VCall, [SimpleString, a]]]]], null]]]",
                 "a = !a || a")
  end

  def test_java_doc
    with_options do
      parser_options do
        skip_java_doc false
      end

      assert_parse '[Script, [[JavaDoc], [MethodDefinition, [SimpleString, a], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [ModifierList]]]]',
                  "/** jdoc */\n def a;end"
      assert_parse '[Script, [[JavaDoc], [MethodDefinition, [SimpleString, a], [Arguments, [RequiredArgumentList], [OptionalArgumentList], null, [RequiredArgumentList], null], null, [], [AnnotationList, [Annotation, [Constant, [SimpleString, Anno]], [HashEntryList]]], [ModifierList]]]]',
                  "/** jdoc */\n $Anno\n def a;end"
      assert_parse '[Script, [[ClassDefinition, [Constant, [SimpleString, a]], null, [], [TypeNameList], [ModifierList]]]]',
                  "/* jdoc */ class a;end"
      assert_parse '[Script, [[ClassDefinition, [Constant, [SimpleString, a]], null, [], [TypeNameList], [AnnotationList, [Annotation, [Constant, [SimpleString, Anno]], [HashEntryList]]], [ModifierList]], [JavaDoc]]]',
                    "$Anno \n class a;end\n/** jdoc */"
      assert_parse '[Script, [[JavaDoc], [MacroDefinition, [SimpleString, a], null, []]]]',
                  "/** jdoc */\nmacro def a;end"
      ast = parse('/** jdoc */; def a;end')
      assert_equal('/** jdoc */',  ast.body(1).java_doc.value)
      assert_equal(nil, ast.body(0).java_doc)
    end
  end

  def test_cast
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, A]], [FieldAccess, [SimpleString, x]]]]]",
                 '@x:A'
    assert_parse("[Script, [[FieldAssign, [SimpleString, x], [Cast, [Constant, [SimpleString, A]], [FieldAccess, [SimpleString, y]]], [ModifierList], null]]]",
                 "@x=@y:A")
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, int]], [FunctionalCall, [SimpleString, int], [], null]]]]",
                 'int():int'
    assert_parse("[Script, [[LocalAssignment, [SimpleString, x], [Call, [[Cast, [Constant, [SimpleString, int]], [FunctionalCall, [SimpleString, int], [], null]]], [SimpleString, y], [], null], null]]]",
                 "x = (int():int).y")
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, int]], [If, [VCall, [SimpleString, a]], [[VCall, [SimpleString, b]]], []]]]]",
                'if a;b;end:int'
    assert_parse "[Script, [[Cast, [Colon2, [Constant, [SimpleString, mmeta]], [Constant, [SimpleString, BaseParser]]], [If, [VCall, [SimpleString, a]], [[VCall, [SimpleString, b]]], []]]]]",
                 'if a;b;end:mmeta::BaseParser'
    assert_parse("[Script, [[Cast, [TypeRefImpl, mmeta.BaseParser, array], [If, [VCall, [SimpleString, a]], [[VCall, [SimpleString, b]]], []]]]]",
                 "if a;b;end:mmeta::BaseParser[]")
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, int]], [Constant, [SimpleString, X]]]]]",
                 'X:int'
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, int]], [VCall, [SimpleString, x]]]]]",
                 'x:int'
    assert_parse "[Script, [[Call, [Cast, [Constant, [SimpleString, int]], [VCall, [SimpleString, x]]], [SimpleString, y], [], null]]]",
                 'x:int.y'
    assert_parse "[Script, [[Call, [Cast, [Constant, [SimpleString, int]], [FunctionalCall, [SimpleString, x], [[VCall, [SimpleString, b]]], null]], [SimpleString, y], [], null]]]",
                   'x(b):int.y'
    assert_parse "[Script, [[Call, [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, x]]], [SimpleString, y], [[Cast, [Constant, [SimpleString, B]], [VCall, [SimpleString, c]]]], null]]]",
                 'x:A.y c:B'
    assert_parse "[Script, [[Call, [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, x]]], [SimpleString, y], [[Cast, [Constant, [SimpleString, B]], [VCall, [SimpleString, c]]]], null]]]",
                 'x:A.y(c:B)'
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, B]], [Call, [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, x]]], [SimpleString, y], [], null]]]]",
                 'x:A.y():B'
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, B]], [Call, [VCall, [SimpleString, x]], [SimpleString, y], [], null]]]]",
                 'x.y:B'
    assert_parse "[Script, [[Cast, [Constant, [SimpleString, B]], [Call, [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, x]]], [SimpleString, y], [], null]]]]",
                 'x:A.y:B'
    assert_parse "[Script, [[LocalAssignment, [SimpleString, short], [Cast, [Constant, [SimpleString, String]], [Call, [FieldAccess, [SimpleString, names]], [SimpleString, []], [[VCall, [SimpleString, name]]], null]], null]]]",
                 'short = @names[name]:String'
    assert_parse "[Script, [[LocalAssignment, [SimpleString, y], [Cast, [Constant, [SimpleString, B]], [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, x]]]], null]]]",
                 'y = x:A:B'
    assert_parse "[Script, [[Hash, [HashEntry, [SimpleString, a], [Call, [Cast, [Constant, [SimpleString, b]], [Call, [Constant, [SimpleString, A]], [SimpleString, x], [], null]], [SimpleString, y], [], null]]]]]",
                 '{a: A.x:b.y}'
  end

  def test_cast_pending
    # TODO why pend not working?!
    #assert_parse "[Script, [[Hash, [HashEntry, [SimpleString, a], [Call, [Cast, [Constant, [SimpleString, b]], [Call, [Constant, [SimpleString, A]], [SimpleString, x], [], null]], [SimpleString, y], [], null]]]]]",
    #               '{a:A.x: b.y}'
  end

  def test_lhs_cast
    assert_parse("[Script, [[LocalAssignment, [SimpleString, x], [VCall, [SimpleString, y]], [Constant, [SimpleString, A]]]]]",
                 "x:A = y")
    assert_parse("[Script, [[FieldAssign, [SimpleString, x], [VCall, [SimpleString, y]], [ModifierList], [Constant, [SimpleString, A]], static]]]",
                 "@@x:A = y")
    assert_parse("[Script, [[ConstantAssign, [SimpleString, C], [Cast, [Constant, [SimpleString, B]], [Call, [Cast, [Constant, [SimpleString, A]], [VCall, [SimpleString, y]]], [SimpleString, z], [], null]], [ModifierList], [Constant, [SimpleString, A]]]]]",
                 "C:A = y:A.z:B")
    assert_parse("[Script, [[FieldAssign, [SimpleString, x], [Hash, [HashEntry, [SimpleString, a], [Fixnum, 1]]], [ModifierList], [Constant, [SimpleString, A]]]]]",
                 "@x:A = {a: 1}")
    assert_parse("[Script, [[LocalAssignment, [SimpleString, x], [If, [VCall, [SimpleString, a]], [[VCall, [SimpleString, b]]], []], [Constant, [SimpleString, int]]]]]",
                 "x:int = if a;b;end")
  end

  # Test different cases a-1 => a(-1) vs a - 1 => a - 1
  # a-1 => (local a minus 1) handled at compiler infer time
  def test_unary_arguments
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, -], [[Fixnum, 1]], null]]]',
                 'a-1')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, -], [[Fixnum, 1]], null]]]',
                 'a - 1')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], null]]]',
                 'a -1')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], null]]]',
                 'a.a -1')
    assert_parse('[Script, [[Call, [Call, [VCall, [SimpleString, a]], [SimpleString, a], [], null], [SimpleString, -], [[Fixnum, 1]], null]]]',
                 'a.a-1')
    assert_parse('[Script, [[Call, [Call, [VCall, [SimpleString, a]], [SimpleString, a], [], null], [SimpleString, -], [[Fixnum, 1]], null]]]',
                 'a.a - 1')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null], [Fixnum, 2], [Fixnum, 3]], null]]]',
                 'a -1, 2, 3')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null], [Fixnum, 2], [Fixnum, 3]], null]]]',
                 'a.a -1, 2, 3')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, a], [[Fixnum, 1], [Call, [Fixnum, 2], [SimpleString, -@], [], null], [Fixnum, 3]], null]]]',
                 'a.a 1,-2, 3')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [VCall, [SimpleString, a]], [SimpleString, -@], [], null]], null]]]',
                 'a(-a)')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, -], [[VCall, [SimpleString, a]]], null]]]',
                 'a-a')
    assert_parse('[Script, [[Call, [FieldAccess, [SimpleString, a]], [SimpleString, -@], [], null]]]',
                 '-@a')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [FieldAccess, [SimpleString, a]], [SimpleString, -@], [], null]], null]]]',
                 'a -@a')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, +@], [], null], [Call, [FieldAccess, [SimpleString, b]], [SimpleString, +@], [], null]], null]]]',
                 'a +1,+@b')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Call, [VCall, [SimpleString, a]], [SimpleString, b], [], null], [SimpleString, -@], [], null]], null]]]',
                 'a -a.b')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [VCall, [SimpleString, d]], [SimpleString, -], [[Fixnum, 2]], null], [Fixnum, 1]], null]]]',
                 'a d-2, 1')
    assert_parse('[Script, [[Call, [[Call, [VCall, [SimpleString, a]], [SimpleString, +], [[VCall, [SimpleString, b]]], null]], [SimpleString, -@], [], null]]]',
                 '-(a + b)')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Fixnum, 1], [Call, [VCall, [SimpleString, a]], [SimpleString, -], [[VCall, [SimpleString, b]]], null], [Fixnum, 2]], null]]]',
                 'a 1, a-b,2')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Call, [VCall, [SimpleString, b]], [SimpleString, +], [[VCall, [SimpleString, c]]], null], [SimpleString, -@], [], null]], null]]]',
                 'a -b-c')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, b], [[Call, [Call, [VCall, [SimpleString, c]], [SimpleString, +], [[VCall, [SimpleString, d]]], null], [SimpleString, -@], [], null]], null]]]',
                 'a.b -c-d')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Fixnum, 1], [Call, [Call, [VCall, [SimpleString, a]], [SimpleString, b], [], null], [SimpleString, -], [[VCall, [SimpleString, b]]], null]], null]]]',
                 'a(1, a.b - b)')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Fixnum, 1], [Call, [Call, [VCall, [SimpleString, a]], [SimpleString, b], [], null], [SimpleString, -], [[VCall, [SimpleString, b]]], null]], null]]]',
                 'a(1, a.b-b)')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], [Block, null, []]]]]',
                 'a -1 do;end')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], [Block, null, []]]]]',
                 'a -1 {}')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, a], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], [Block, null, []]]]]',
                 'a.a -1 {}')
    assert_parse('[Script, [[Call, [Self], [SimpleString, a], [[Call, [Call, [VCall, [SimpleString, b]], [SimpleString, -], [[VCall, [SimpleString, c]]], null], [SimpleString, -@], [], null]], [Block, null, []]]]]',
                 'self.a -b+c do;end')
    assert_parse('[Script, [[If, [Boolean, true], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]], [[Fixnum, 1]]]]]',
                 'true ? -1 : 1')
    assert_parse('[Script, [[If, [Boolean, true], [[Fixnum, 1]], [[Call, [Fixnum, 1], [SimpleString, -@], [], null]]], [FunctionalCall, [SimpleString, call], [], [Block, null, []]]]]',
                 'true ? 1 : -1; call do;end')
    assert_parse('[Script, [[If, [Boolean, true], [[Fixnum, 1]], [[Call, [FunctionalCall, [SimpleString, call], [], [Block, null, []]], [SimpleString, -@], [], null]]]]]',
                 'true ? 1 : -call do;end')
    assert_parse('[Script, [[Call, [Cast, [Constant, [SimpleString, Long]], [Fixnum, 1]], [SimpleString, -@], [], null]]]',
                 '-1:Long')
  end

  # Test different cases a-1 => a(-1) vs a - 1 => a - 1
  # a-1 => (local a minus 1) handled at compiler infer time
  def test_brace_vs_do_blocks
    assert_parse('[Script, [[FunctionalCall, [SimpleString, f_call], [[VCall, [SimpleString, arg]]], [Block, null, []]]]]',
                 'f_call arg do;end')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, f_call], [[FunctionalCall, [SimpleString, f_arg], [[Hash]], null]], null]]]',
                 'f_call f_arg {}')
    assert_parse('[Script, [[FunctionalCall, [SimpleString, f_call], [[FunctionalCall, [SimpleString, f_arg], [], [Block, null, []]]], null]]]',
                 'f_call f_arg {;}')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[FunctionalCall, [SimpleString, f_arg], [], [Block, null, []]]], null]]]',
                 'a.call f_arg {;}')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[VCall, [SimpleString, arg]]], [Block, null, []]]]]',
                 'a.call arg do;end')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[VCall, [SimpleString, arg]], [FunctionalCall, [SimpleString, f_arg], [], [Block, null, []]]], null]]]',
                 'a.call arg, f_arg {;}')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[VCall, [SimpleString, arg1]], [VCall, [SimpleString, arg2]]], [Block, null, []]]]]',
                 'a.call arg1, arg2 do;end')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[Call, [VCall, [SimpleString, arg1]], [SimpleString, call1], [], [Block, null, []]]], null]]]',
                 'a.call arg1.call1 {;}')
    assert_parse('[Script, [[Call, [VCall, [SimpleString, a]], [SimpleString, call], [[Call, [VCall, [SimpleString, arg1]], [SimpleString, call1], [], null]], [Block, null, []]]]]',
                 'a.call arg1.call1 do;end')
  end
end