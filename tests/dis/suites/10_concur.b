implement ConcurTest;

#
# Avenue 4: concurrency + GC stress.
# Exercises the Dis scheduler, channels (buffered + unbuffered), alt, spawn,
# channel-of-references, a classic concurrent prime sieve (one proc per prime),
# and heavy allocation to force many GC cycles while a live structure must
# survive intact (validates the LP64 GC pointer-map traversal).
#
include "sys.m";
include "draw.m";
include "testing.m";

sys: Sys;
t: Testing;

ConcurTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# --- worker fan-in ---
worker(id: int, c: chan of int)
{
	c <-= id;
}

# --- concurrent prime sieve ---
# A -1 sentinel is propagated through the whole pipeline so every proc
# terminates cleanly once the producer is exhausted (no leaked procs).
counter(c: chan of int, limit: int)
{
	for(i := 2; i <= limit; i++)
		c <-= i;
	c <-= -1;
}

filter(prime: int, in, out: chan of int)
{
	for(;;){
		i := <-in;
		if(i == -1){
			out <-= -1;		# pass the sentinel downstream, then exit
			return;
		}
		if(i % prime != 0)
			out <-= i;
	}
}

sieve(primes: chan of int)
{
	c := chan of int;
	spawn counter(c, 100);
	for(;;){
		p := <-c;
		if(p == -1){
			primes <-= -1;
			return;
		}
		primes <-= p;
		nc := chan of int;
		spawn filter(p, c, nc);
		c = nc;
	}
}

# --- request/reply over a channel of references ---
Req: adt {
	x:	int;
	reply:	chan of int;
};

server(reqc: chan of ref Req)
{
	for(;;){
		r := <-reqc;
		if(r.reply == nil)		# stop sentinel
			return;
		r.reply <-= r.x * r.x;
	}
}

# --- a retained linked structure for the GC stress ---
Node: adt {
	val:	int;
	tag:	string;		# pointer field, must survive GC
	next:	cyclic ref Node;
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	# --- fan-in: 100 spawned workers each report their id ---
	c := chan of int;
	N := 100;
	for(i := 0; i < N; i++)
		spawn worker(i, c);
	sum := 0;
	for(i = 0; i < N; i++)
		sum += <-c;
	t->eqi(big sum, big (N*(N-1)/2), "fan-in 100 workers sum");

	# --- buffered channel: send buffer-full without a receiver, then drain ---
	bc := chan[3] of int;
	bc <-= 10;
	bc <-= 20;
	bc <-= 30;			# would block on an unbuffered channel
	t->eqi(big (<-bc + <-bc + <-bc), big 60, "buffered channel drain");

	# --- buffered channel of size 1 as a mutex (addendum locking idiom) ---
	lk := chan[1] of int;
	lk <-= 0;			# acquire
	<-lk;				# release
	lk <-= 0;			# re-acquire (would deadlock if release failed)
	t->ok(1, "buffered chan mutex acquire/release");

	# --- alt over multiple channels ---
	a := chan of int;
	b := chan of int;
	spawn sender(a, 111);
	spawn sender(b, 222);
	got := 0;
	for(i = 0; i < 2; i++){
		alt {
		v := <-a =>	got += v;
		v := <-b =>	got += v;
		}
	}
	t->eqi(big got, big 333, "alt two channels");

	# --- concurrent prime sieve: capture 2nd and 10th prime, then drain to
	# the sentinel so the whole pipeline shuts down (no leaked procs) ---
	primes := chan of int;
	spawn sieve(primes);
	p2 := 0;
	p10 := 0;
	k := 0;
	for(;;){
		p := <-primes;
		if(p == -1)
			break;
		k++;
		if(k == 2)
			p2 = p;
		if(k == 10)
			p10 = p;
	}
	t->eqi(big p2, big 3, "sieve 2nd prime");
	t->eqi(big p10, big 29, "sieve 10th prime");
	t->eqi(big k, big 25, "sieve found 25 primes below 100");

	# --- request/reply over channel of ref ---
	reqc := chan of ref Req;
	spawn server(reqc);
	rsum := 0;
	for(i = 1; i <= 5; i++){
		rep := chan of int;
		reqc <-= ref Req(i, rep);
		rsum += <-rep;
	}
	reqc <-= ref Req(0, nil);		# tell the server to exit
	t->eqi(big rsum, big 55, "chan-of-ref request/reply (sum of squares 1..5)");

	# --- GC stress: build a retained list, churn garbage, verify integrity ---
	head: ref Node;
	want := 0;
	for(i = 0; i < 500; i++){
		head = ref Node(i, sys->sprint("n%d", i), head);
		want += i;
	}
	# churn: allocate and discard large arrays of pointers, forcing GC
	for(i = 0; i < 4000; i++){
		junk := array[256] of ref Node;
		for(j := 0; j < len junk; j++)
			junk[j] = ref Node(j, "junk", nil);
		junk = nil;
	}
	# now verify the retained structure survived intact
	got2 := 0;
	cnt := 0;
	tagok := 1;
	for(n := head; n != nil; n = n.next){
		got2 += n.val;
		if(n.tag != sys->sprint("n%d", n.val))
			tagok = 0;
		cnt++;
	}
	t->eqi(big cnt, big 500, "GC: retained list length");
	t->eqi(big got2, big want, "GC: retained list value sum");
	t->ok(tagok, "GC: retained list pointer (string) fields intact");

	t->summary();
}

sender(c: chan of int, v: int)
{
	c <-= v;
}
