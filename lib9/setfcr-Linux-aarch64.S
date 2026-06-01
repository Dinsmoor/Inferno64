	.file	"setfcr-aarch64.S"
	.text
	.text

/*
 * setfcr - set floating-point control register
 * a0 = new FCR value
 */
	.global setfcr
	.type	setfcr, %function
setfcr:
	msr	fpcr, x0
	ret
	.size	setfcr, .-setfcr

/*
 * getfcr - get floating-point control register
 * returns FCR value in x0
 */
	.global getfcr
	.type	getfcr, %function
getfcr:
	mrs	x0, fpcr
	ret
	.size	getfcr, .-getfcr

/*
 * setfsr - set floating-point status register
 * a0 = new FSR value
 */
	.global setfsr
	.type	setfsr, %function
setfsr:
	msr	fpsr, x0
	ret
	.size	setfsr, .-setfsr

/*
 * getfsr - get floating-point status register
 * returns FSR value in x0
 */
	.global getfsr
	.type	getfsr, %function
getfsr:
	mrs	x0, fpsr
	ret
	.size	getfsr, .-getfsr
