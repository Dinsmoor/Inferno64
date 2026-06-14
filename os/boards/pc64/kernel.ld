OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS
{
	. = 0x100000;
	.text : {
		*(.multiboot)		/* multiboot header — must be in the first 8KB */
		*(.text.boot)
		*(.text*)
	}
	. = ALIGN(16);
	etext = .;
	.rodata : {
		*(.rodata*)
	}
	.data : {
		*(.data*)
		*(.got)
		*(.got.plt)
	}
	. = ALIGN(16);
	edata = .;
	.bss : {
		*(.bss*)
		*(COMMON)
	}
	. = ALIGN(16);
	end = .;
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
