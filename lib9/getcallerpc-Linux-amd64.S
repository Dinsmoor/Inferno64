	.file	"getcallerpc-Linux-amd64.S"
	.text
	/*
	 * getcallerpc - amd64 version.
	 *
	 * The real implementation is the static __inline in lib9.h
	 * (return (uintptr)__builtin_return_address(0)), so callers get the
	 * address in their own frame.  This symbol is kept only for build-system
	 * compatibility (cf. getcallerpc-Linux-aarch64.S).
	 */
	.type	getcallerpc,@function
	.global	getcallerpc
getcallerpc:
	movq	(%rsp), %rax
	ret
