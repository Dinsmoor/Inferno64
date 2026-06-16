Titletex: module
{
	PATH:	con "/dis/lib/titletex.dis";

	# Decorative window-titlebar styles.  FLAT means "no texture, use the plain
	# themed -bg label"; CASTLE and TEMPLE are procedurally drawn stone bars.
	FLAT, CASTLE, TEMPLE: con iota;

	init:		fn(d: ref Draw->Display);

	# Map a theme "titlestyle" word to a style id; unknown / "flat" -> FLAT.
	styleid:	fn(name: string): int;

	# Render a w x h titlebar texture for `style`, with `title` baked in at the
	# left.  `focused` brightens the palette (the focused-window tint); `fg` is
	# the title-text colour as a Draw RGBA int.  Returns nil if uninitialised,
	# if style is FLAT, or on allocation failure.
	render:		fn(style, w, h, focused: int, title: string, fg: int): ref Draw->Image;
};
