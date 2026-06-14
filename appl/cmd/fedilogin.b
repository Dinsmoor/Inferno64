implement Fedilogin;

#
# fedilogin -- log a fedifs account in without putting the password on screen.
#
#   fedilogin [-o] <host|user@host> [mountpoint]
#
# Prompts for the password with terminal echo off (and the username too, for a
# bare host) and writes the login command to the account's ctl file under the
# fedifs mount (default /mnt/fedi).  For multiple accounts on one instance use
# the user@host form, e.g. `fedilogin alice@poa.st`; each is its own session.
#
# This is only a convenience wrapper over the file interface:
#   echo 'login <user> <pass>' > /mnt/fedi/<host>/ctl          # bare host
#   echo 'login <pass>'        > /mnt/fedi/<user@host>/ctl     # named account
#
# With -o it runs the OAuth authorization-code ("oob") flow instead, for
# instances that reject the password grant: it stages an authorize URL, prints
# it for the user to open in a browser, and exchanges the pasted-back code.  The
# password is never typed into Inferno.  Same file interface:
#   echo authbegin       > /mnt/fedi/<label>/ctl   ; cat /mnt/fedi/<label>/authurl
#   echo 'authcode <c>'  > /mnt/fedi/<label>/ctl
#

include "sys.m";
	sys: Sys;

include "draw.m";

Fedilogin: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

RAWON, RAWOFF: con iota;

stdin, stdout, stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	argv = tl argv;
	oob := 0;
	if(argv != nil && hd argv == "-o"){
		oob = 1;
		argv = tl argv;
	}
	if(argv == nil){
		sys->fprint(stderr, "usage: fedilogin [-o] <host|user@host> [mountpoint]\n");
		raise "fail:usage";
	}
	label := hd argv;
	mnt := "/mnt/fedi";
	if(tl argv != nil)
		mnt = hd tl argv;
	ctl := mnt + "/" + label + "/ctl";

	if(oob)
		ooblogin(mnt, label, ctl);
	else
		passlogin(label, ctl);

	# echo the resulting status so the user sees success or the error
	rfd := sys->open(ctl, Sys->OREAD);
	if(rfd != nil){
		buf := array[1024] of byte;
		n := sys->read(rfd, buf, len buf);
		if(n > 0)
			sys->print("%s", string buf[0:n]);
	}
}

# resource-owner password grant: prompt user (if needed) + password, no echo
passlogin(label, ctl: string)
{
	user := userfromlabel(label);
	if(user == "")
		user = prompt("User", RAWOFF);
	pass := prompt("Password", RAWON);
	if(pass == ""){
		sys->fprint(stderr, "fedilogin: empty password\n");
		raise "fail:pass";
	}
	cmd: string;
	if(userfromlabel(label) != "")
		cmd = "login " + pass;		# user is in the node name
	else
		cmd = "login " + user + " " + pass;
	ctlwrite(ctl, cmd, "login");
}

# OAuth authorization-code flow driven entirely through the fedifs namespace:
# stage the URL (authbegin), read it back (authurl), have the user approve it in
# a browser, then exchange the code (authcode).  Inferno never sees the password.
ooblogin(mnt, label, ctl: string)
{
	ctlwrite(ctl, "authbegin", "authbegin");
	url := readall(mnt + "/" + label + "/authurl");
	if(url == ""){
		sys->fprint(stderr, "fedilogin: no authorize URL was issued\n");
		raise "fail:authurl";
	}
	sys->print("Open this URL in a browser, approve, and copy the code shown:\n\n");
	sys->print("    %s\n\n", url);
	code := prompt("Code", RAWOFF);
	if(code == ""){
		sys->fprint(stderr, "fedilogin: empty code\n");
		raise "fail:code";
	}
	ctlwrite(ctl, "authcode " + code, "authcode");
}

# write a single ctl command, mapping a short write to an error
ctlwrite(ctl, cmd, what: string)
{
	fd := sys->open(ctl, Sys->OWRITE);
	if(fd == nil){
		sys->fprint(stderr, "fedilogin: open %s: %r\n", ctl);
		raise "fail:open";
	}
	b := array of byte cmd;
	if(sys->write(fd, b, len b) != len b){
		sys->fprint(stderr, "fedilogin: %s failed: %r\n", what);
		raise "fail:" + what;
	}
}

# read a small file fully and trim trailing newlines
readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

# the username encoded in a "user@host" label ("" for a bare host)
userfromlabel(label: string): string
{
	s := label;
	if(len s > 0 && s[0] == '@')
		s = s[1:];
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '@')
			return s[0:i];
	return "";
}

prompt(p: string, mode: int): string
{
	sys->fprint(stdout, "%s: ", p);
	return readline(stdin, mode);
}

# read one line; with mode RAWON the console echo is suppressed (each typed
# character shown as '*'), modelled on cmd/promptstring.b
readline(fd: ref Sys->FD, mode: int): string
{
	ctl: ref Sys->FD;
	if(mode == RAWON){
		ctl = sys->open("/dev/consctl", Sys->OWRITE);
		if(ctl == nil || sys->write(ctl, array of byte "rawon", 5) != 5){
			sys->fprint(stderr, "fedilogin: cannot set rawon: %r\n");
			ctl = nil;
		}
	}
	buf := array[256] of byte;
	tmp := array[256] of byte;
	sofar := 0;
	while(sofar < len buf){
		i := sys->read(fd, tmp, len buf - sofar);
		if(i <= 0)
			break;
		done := 0;
		for(j := 0; j < i; j++){
			if(tmp[j] == byte '\n'){
				done = 1;
				break;
			}
			buf[sofar++] = tmp[j];
			if(mode == RAWON)
				sys->write(stdout, array of byte "*", 1);
		}
		if(done)
			break;
	}
	if(mode == RAWON){
		sys->write(stdout, array of byte "\n", 1);
		if(ctl != nil)
			sys->write(ctl, array of byte "rawoff", 6);
	}
	return string buf[0:sofar];
}
