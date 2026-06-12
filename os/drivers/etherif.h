/*
 * simplified from os/pc/etherif.h: no ISAConf/PCI here — the only bus
 * is virtio-mmio, so a driver's reset() does its own probing and fills
 * in what it found.  irq < 0 means the driver manages its own interrupt
 * (the virtio transport's virtiointrenable) and devether stays out of it.
 */
enum {
	MaxEther	= 4,
	Ntypes		= 8,
};

typedef struct Ether Ether;
struct Ether {
	int	ctlrno;
	int	irq;
	int	minmtu;
	int 	maxmtu;
	uchar	ea[Eaddrlen];

	void	(*attach)(Ether*);	/* filled in by reset routine */
	void	(*detach)(Ether*);
	void	(*transmit)(Ether*);
	void	(*interrupt)(Ureg*, void*);
	long	(*ifstat)(Ether*, void*, long, ulong);
	long 	(*ctl)(Ether*, void*, long); /* custom ctl messages */
	void	(*power)(Ether*, int);	/* power on/off */
	void	(*shutdown)(Ether*);	/* shutdown hardware before reboot */
	void	*ctlr;

	Queue*	oq;

	Netif;
};

extern Block* etheriq(Ether*, Block*, int);
extern void addethercard(char*, int(*)(Ether*));
extern ulong ethercrc(uchar*, int);
extern int parseether(uchar*, char*);
