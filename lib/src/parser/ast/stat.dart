// From LuaDardo (Apache 2.0); see lib/src/parser/README.md.
// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'block.dart';
import 'exp.dart';
import 'node.dart';

/*
stat ::=  ‘;’ |
	 varlist ‘=’ explist |
	 functioncall |
	 label |
	 break |
	 goto Name |
	 do block end |
	 while exp do block end |
	 repeat block until exp |
	 if exp then block {elseif exp then block} [else block] end |
	 for Name ‘=’ exp ‘,’ exp [‘,’ exp] do block end |
	 for namelist in explist do block end |
	 function funcname funcbody |
	 local function Name funcbody |
	 global function Name funcbody |
	 local attnamelist [‘=’ explist] |
	 global attnamelist [‘=’ explist] |
	 global [attrib] ‘*’
*/
abstract class Stat extends Node {}

class EmptyStat extends Stat {
  static final EmptyStat instance = EmptyStat();
}

class BreakStat extends Stat {
  BreakStat(int line) {
    super.line = line;
  }
}

class LabelStat extends Stat {
  String name;

  LabelStat(this.name);
}

class GotoStat extends Stat {
  String name;

  GotoStat(this.name);
}

class DoStat extends Stat {
  Block block;

  DoStat(this.block);
}

class FuncCallStat extends Stat {
  FuncCallExp exp;

  FuncCallStat(this.exp);
}

class WhileStat extends Stat {
  Exp exp;
  Block block;

  WhileStat(this.exp, this.block);
}

class RepeatStat extends Stat {
  Block block;
  Exp exp;

  RepeatStat(this.block, this.exp);
}

class IfStat extends Stat {
  List<Exp> exps;
  List<Block> blocks;

  IfStat(this.exps, this.blocks);
}

class ForNumStat extends Stat {
  int lineOfFor;
  int lineOfDo;
  String varName;
  Exp initExp;
  Exp limitExp;
  Exp stepExp;
  Block block;

  ForNumStat({
    required this.lineOfFor,
    required this.lineOfDo,
    required this.varName,
    required this.initExp,
    required this.limitExp,
    required this.stepExp,
    required this.block,
  });
}

class ForInStat extends Stat {
  int lineOfDo;
  List<String> nameList;
  List<Exp> expList;
  Block block;

  ForInStat({
    required this.lineOfDo,
    required this.nameList,
    required this.expList,
    required this.block,
  });
}

/// The attribute of a variable: `local x <const>`, `local f <close>`,
/// `global <const> x`. A global can only be `<const>`.
enum LocalAttrib { const_, close }

class LocalVarDeclStat extends Stat {
  List<String> nameList;
  List<Exp> expList;

  /// The attribute of each name in [nameList], or null if no name has one.
  List<LocalAttrib?>? attribList;

  LocalVarDeclStat(
    int lastLine,
    this.nameList,
    this.expList, [
    this.attribList,
  ]) {
    super.lastLine = lastLine;
  }
}

class AssignStat extends Stat {
  List<Exp> varList;
  List<Exp> expList;

  AssignStat(int lastLine, this.varList, this.expList) {
    super.lastLine = lastLine;
  }
}

class LocalFuncDefStat extends Stat {
  String name;
  FuncDefExp exp;

  LocalFuncDefStat(this.name, this.exp);
}

/// `global namelist [‘=’ explist]` (Lua 5.5): declares the names as
/// globals, and assigns them if [expList] is not empty. After a `global`
/// declaration, a free name must be declared.
class GlobalVarDeclStat extends Stat {
  List<String> nameList;
  List<Exp> expList;

  /// The attribute of each name in [nameList], or null if no name has one.
  /// Only [LocalAttrib.const_].
  List<LocalAttrib?>? attribList;

  GlobalVarDeclStat(
    int lastLine,
    this.nameList,
    this.expList, [
    this.attribList,
  ]) {
    super.lastLine = lastLine;
  }
}

/// `global [attrib] ‘*’` (Lua 5.5): every free name is a global again, with
/// [attrib] if not null.
class GlobalCollectiveDeclStat extends Stat {
  LocalAttrib? attrib;

  GlobalCollectiveDeclStat(int line, this.attrib) {
    super.line = line;
  }
}

/// `global function Name funcbody` (Lua 5.5): declares [name] as a global
/// and assigns the function to it. [name] is visible in the body.
class GlobalFuncDefStat extends Stat {
  String name;
  FuncDefExp exp;

  GlobalFuncDefStat(this.name, this.exp);
}
