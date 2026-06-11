OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

SECTIONS
{
	. = 0x40200000;
	.text : {
		*(.text.boot)
		*(.text*)
	}
	. = ALIGN(16);
	etext = .;
	.rodata : {
		*(.rodata*)
		*(.srodata*)
	}
	.data : {
		*(.data*)
		*(.sdata*)
		*(.got)
		*(.got.plt)
	}
	. = ALIGN(16);
	edata = .;
	.bss : {
		*(.bss*)
		*(.sbss*)
		*(COMMON)
	}
	. = ALIGN(16);
	end = .;
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
