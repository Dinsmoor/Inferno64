	.file	"getcallerpc-aarch64.S"
	.text
	/*
	 * getcallerpc - aarch64 version
	 * 
	 * The actual implementation is via inline assembly in lib9.h:
	 *   mov %0, x30    (load link register)
	 *
	 * This file is kept for compatibility with the build system.
	 */
	.global getcallerpc
	getcallerpc:
	ret
