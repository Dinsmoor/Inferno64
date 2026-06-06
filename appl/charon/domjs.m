Domjs: module
{
	PATH:	con "/dis/charon/domjs.dis";

	#
	# The JavaScript-facing DOM: binds Charon's retained element tree
	# (Dom->Node) to the ECMAScript engine as host objects.  It is deliberately
	# decoupled from the rest of Charon (depends only on Ecmascript + Dom), so it
	# can be unit-tested by driving the engine directly; jscript.b wires it onto
	# each frame's window.document and supplies the reflow callback.
	#
	# Exposes:
	#   document.getElementById(id) / .getElementsByTagName(tag) / .createElement(tag)
	#   document.documentElement / .body
	#   element.tagName .nodeName .nodeType .id .className .textContent
	#           .parentNode .firstChild .nextSibling
	#   element.getAttribute(n) .setAttribute(n,v) .appendChild(c) .removeChild(c)
	#

	# call after the engine (Ecmascript) is loaded AND initialised; pass that same
	# handle so domjs shares the engine's well-known values (null/undefined/...).
	init:	fn(es: Ecmascript);

	# install `document` (bound to the tree at root) as a property of scope (the
	# JS global / Window) and return it.  reflow, if non-nil, is invoked after any
	# script-driven mutation of the tree.  (Standalone path / unit tests.)
	install:	fn(ex: ref Ecmascript->Exec, scope: ref Ecmascript->Obj,
			root: ref Dom->Node, reflow: ref fn()): ref Ecmascript->Obj;

	# Granular helpers, for hosts (jscript.b) that keep their own legacy
	# `document` object and only want to add the DOM query/factory methods.
	# Each returns/operates on domjs-hosted element objects.
	setreflow:	fn(reflow: ref fn());
	serialize:	fn(root: ref Dom->Node): string;	# DOM subtree -> re-parseable HTML
	elembyid:	fn(ex: ref Ecmascript->Exec, root: ref Dom->Node, id: string): ref Ecmascript->Val;
	elembytag:	fn(ex: ref Ecmascript->Exec, root: ref Dom->Node, tag: string): ref Ecmascript->Val;
	createelem:	fn(ex: ref Ecmascript->Exec, tag: string): ref Ecmascript->Val;

	# ESHostobj method suite (domjs hosts the document + element objects).
	get:		fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, property: string): ref Ecmascript->Val;
	put:		fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, property: string, val: ref Ecmascript->Val);
	canput:		fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, property: string): ref Ecmascript->Val;
	hasproperty:	fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, property: string): ref Ecmascript->Val;
	delete:		fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, property: string);
	defaultval:	fn(ex: ref Ecmascript->Exec, o: ref Ecmascript->Obj, tyhint: int): ref Ecmascript->Val;
	call:		fn(ex: ref Ecmascript->Exec, func, this: ref Ecmascript->Obj, args: array of ref Ecmascript->Val, eval: int): ref Ecmascript->Ref;
	construct:	fn(ex: ref Ecmascript->Exec, func: ref Ecmascript->Obj, args: array of ref Ecmascript->Val): ref Ecmascript->Obj;
};
