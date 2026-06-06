Script: module
{
	JSCRIPTPATH: con "/dis/charon/jscript.dis";

	defaultStatus: string;
	jevchan: chan of ref Events->ScriptEvent;
	versions : array of string;

	init: fn(cu: CharonUtils): string;
	frametreechanged: fn(top: ref Layout->Frame);
	havenewdoc: fn(f: ref Layout->Frame);
	evalscript: fn(f: ref Layout->Frame, s: string) : (string, string, string);
	framedone: fn(f : ref Layout->Frame, hasscripts : int);
	# Whether a script mutated f's DOM since the last check (caller re-renders
	# from f.doc.domroot); clears the flag.
	domdirtied: fn(f: ref Layout->Frame): int;
};
