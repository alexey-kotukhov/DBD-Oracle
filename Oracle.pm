
#   $Id: Oracle.pm,v 1.75 1999/06/08 00:15:02 timbo Exp $
#
#   Copyright (c) 1994,1995,1996,1997,1998,1999 Tim Bunce
#
#   You may distribute under the terms of either the GNU General Public
#   License or the Artistic License, as specified in the Perl README file,
#   with the exception that it cannot be placed on a CD-ROM or similar media
#   for commercial distribution without the prior approval of the author.

require 5.003;

$DBD::Oracle::VERSION = '1.01';

my $ORACLE_ENV  = ($^O eq 'VMS') ? 'ORA_ROOT' : 'ORACLE_HOME';

{
    package DBD::Oracle;

    use DBI ();
    use DynaLoader ();
    use Exporter ();
    @ISA = qw(DynaLoader Exporter);
    %EXPORT_TAGS = (
	ora_types => [ qw(
	    ORA_VARCHAR2 ORA_NUMBER ORA_LONG ORA_ROWID ORA_DATE
	    ORA_RAW ORA_LONGRAW ORA_CHAR ORA_MLSLABEL ORA_NTY
	    ORA_CLOB ORA_BLOB ORA_RSET
	) ],
    );
    @EXPORT_OK = ('ORA_OCI');
    Exporter::export_ok_tags('ora_types');


    my $Revision = substr(q$Revision: 1.75 $, 10);

    require_version DBI 1.02;

    bootstrap DBD::Oracle $VERSION;

    $err = 0;		# holds error code   for DBI::err    (XXX SHARED!)
    $errstr = "";	# holds error string for DBI::errstr (XXX SHARED!)
    $drh = undef;	# holds driver handle once initialised

    sub driver{
	return $drh if $drh;
	my($class, $attr) = @_;
	my $oci = DBD::Oracle::ORA_OCI();

	$class .= "::dr";

	# not a 'my' since we use it above to prevent multiple drivers

	$drh = DBI::_new_drh($class, {
	    'Name' => 'Oracle',
	    'Version' => $VERSION,
	    'Err'    => \$DBD::Oracle::err,
	    'Errstr' => \$DBD::Oracle::errstr,
	    'Attribution' => "DBD::Oracle $VERSION using OCI$oci by Tim Bunce",
	    });

	$drh;
    }


    END {
	# Used to silence 'Bad free() ...' warnings caused by bugs in Oracle's code
	# being detected by Perl's malloc.
	$ENV{PERL_BADFREE} = 0;
    }

	#sub AUTOLOAD {
	#	(my $constname = $AUTOLOAD) =~ s/.*:://;
	#	my $val = constant($constname);
	#	*$AUTOLOAD = sub { $val };
	#	goto &$AUTOLOAD;
	#}

}


{   package DBD::Oracle::dr; # ====== DRIVER ======
    use strict;

    my %dbnames = ();	# holds list of known databases (oratab + tnsnames)

    sub load_dbnames {
	my ($drh) = @_;
	my $debug = $drh->debug;
	my $oracle_home = $ENV{$ORACLE_ENV} || '';
	local *FH;
	my $d;

	if (($^O eq 'MSWin32') or ($^O =~ /cygwin/i)) {
	  # XXX experimental, will probably change
	  $drh->log_msg("Fetching ORACLE_SID from Registry.\n") if $debug;
	  my($hkey, $sid, $home);
	  eval q{
	    require Win32::TieRegistry;
	    $Win32::TieRegistry::Registry->Delimeter("/");
	    $hkey= $Win32::TieRegistry::Registry->{"LMachine/Software/Oracle/"};
	  };
	  eval q{
	    require Tie::Registry;
	    $Tie::Registry::Registry->Delimeter("/");
	    $hkey= $Tie::Registry::Registry->{"LMachine/Software/Oracle/"};
	  } unless $hkey;
	  if ($hkey) {
	    $sid = $hkey->{ORACLE_SID};
	    $home= $hkey->{ORACLE_HOME};
	  } else {
	    eval q{
	      my $reg_key;
	      require Win32::Registry;
	      $main::HKEY_LOCAL_MACHINE->Open('SOFTWARE\ORACLE', $reg_key);
	      $reg_key->GetValues( $hkey );
	      $sid = $hkey->{ORACLE_SID}[2];
	      $home= $hkey->{ORACLE_HOME}[2];
	    };
	  };
	  $home= $ENV{$ORACLE_ENV} unless $home;
	  $dbnames{$sid} = $home if $sid and $home;
	  $drh->log_msg("Found $sid \@ $home.\n") if $debug;
	  $oracle_home =$home unless $oracle_home;
	};

	# get list of 'local' database SIDs from oratab
	foreach $d (qw(/etc /var/opt/oracle), $ENV{TNS_ADMIN}) {
	    next unless defined $d;
	    next unless open(FH, "<$d/oratab");
	    $drh->trace_msg("Loading $d/oratab\n") if $debug;
	    my $ot;
	    while (defined($ot = <FH>)) {
		next unless $ot =~ m/^\s*(\w+)\s*:\s*(.*?)\s*:/;
		$dbnames{$1} = $2;	# store ORACLE_HOME value
		$drh->trace_msg("Found $1 \@ $2.\n") if $debug;
	    }
	    close FH;
	    last;
	}

	# get list of 'remote' database connection identifiers
	foreach $d ( $ENV{TNS_ADMIN},
	  "$oracle_home/net80/admin",
	  "$oracle_home/network/admin",
	  '/var/opt/oracle'
	) {
	    next unless $d && open(FH, "<$d/tnsnames.ora");
	    $drh->trace_msg("Loading $d/tnsnames.ora\n") if $debug;
	    while (<FH>) {
		next unless m/^\s*([-\w\.]+)\s*=/;
		my $name = $1;
		$drh->trace_msg("Found $name. ".($dbnames{$name} ? "(oratab entry overridden)" : "")."\n")
		    if $debug;
		$dbnames{$name} = 0; # exists but false (to distinguish from oratab)
	    }
	    close FH;
	    last;
	}

	$dbnames{0} = 1;	# mark as loaded (even if empty)
    }

    sub data_sources {
	my $drh = shift;
	load_dbnames($drh) unless %dbnames;
	my @names = sort  keys %dbnames;
	my @sources = map { $_ ? ("dbi:Oracle:$_") : () } @names;
	return @sources;
    }


    sub connect {
	my ($drh, $dbname, $user, $auth, $attr)= @_;

	# If the application is asking for specific database
	# then we have to mung the

	if (DBD::Oracle::ORA_OCI() >= 8) {
	    $dbname = $1 if !$dbname && $user =~ s/\@(.*)//;
	}
	elsif ($dbname) {	# OCI 7 handling below

	    # We can use the 'user/passwd@machine' form of user.
	    # $TWO_TASK and $ORACLE_SID will be ignored in that case.
	    if ($dbname =~ /@/){	# Implies an Sql*NET connection
		$user = "$user/$auth$dbname";
		$auth = "";
	    }
	    elsif ($dbname =~ /:/){	# Implies an Sql*NET connection
		$user = "$user/$auth".'@'.$dbname;
		$auth = "";
	    }
	    else {
		# Is this a NON-Sql*NET connection (ORACLE_SID)?
		# Or is it an alias for an Sql*NET connection (TWO_TASK)?
		# Sadly the 'user/passwd@machine' form only works
		# for Sql*NET connections.
		load_dbnames($drh) unless %dbnames;
		if (exists $dbnames{$dbname}) {		# known name
		    my $dbhome = $dbnames{$dbname};	# local=>ORACLE_HOME, remote=>0
		    if ($dbhome) {
			$ENV{ORACLE_SID}  = $dbname;
			delete $ENV{TWO_TASK};
			if ($attr && $attr->{ora_oratab_orahome}) {
			    warn "Changing $ORACLE_ENV for $dbname to $dbhome (to match oratab entry)"
				if ($ENV{$ORACLE_ENV} and $dbhome ne $ENV{$ORACLE_ENV});
			    $ENV{$ORACLE_ENV} = $dbhome;
			}
		    }
		    else {
			$user .= '@'.$dbname;	# it's a known TNS alias
		    }
		}
		else {
		    $user .= '@'.$dbname;	# assume it's a TNS alias
		}
	    }
	}

	warn "$ORACLE_ENV environment variable not set!\n"
		if !$ENV{$ORACLE_ENV} and $^O ne "MSWin32";

	# create a 'blank' dbh

	my $dbh = DBI::_new_dbh($drh, {
	    'Name' => $dbname,
	    'USER' => $user, 'CURRENT_USER' => $user,
	    });

	# Call Oracle OCI logon func in Oracle.xs file
	# and populate internal handle data.
	DBD::Oracle::db::_login($dbh, $dbname, $user, $auth)
	    or return undef;

	if ($attr && $attr->{ora_module_name}) {
	    eval {
		$dbh->do(q{BEGIN DBMS_APPLICATION_NAME.SET_MODULE(:1,NULL); END;},
		       undef, $attr->{ora_module_name});
	    };
	}

	$dbh;
    }

}


{   package DBD::Oracle::db; # ====== DATABASE ======
    use strict;

    sub prepare {
	my($dbh, $statement, @attribs)= @_;

	# create a 'blank' sth

	my $sth = DBI::_new_sth($dbh, {
	    'Statement' => $statement,
	    });

	# Call Oracle OCI parse func in Oracle.xs file.
	# and populate internal handle data.

	DBD::Oracle::st::_prepare($sth, $statement, @attribs)
	    or return undef;

	$sth;
    }


    sub ping {
	my($dbh) = @_;
	my $ok = 0;
	local $SIG{__WARN__} = sub { } if $dbh->{PrintError};
	eval {
	    # we know that Oracle 7 prepare does a describe so this will
	    # actually talk to the server and is this a valid and cheap test.
	    my $sth =  $dbh->prepare("select SYSDATE from DUAL /* ping */");
	    # But Oracle 8 doesn't talk to server unless we describe the query
	    $ok = $sth && $sth->{NUM_OF_FIELDS};
	};
	return ($@) ? 0 : $ok;
    }


    sub table_info {
	my($dbh) = @_;		# XXX add qualification
	# XXX add knowledge of public synonmys views etc
	# The SYS/SYSTEM should probably be a decode that
	# prepends 'SYSTEM ' to TABLE_TYPE.
	my $sth = $dbh->prepare("select
		NULL		TABLE_CAT,
		at.OWNER	TABLE_SCHEM,
		at.TABLE_NAME,
		tc.TABLE_TYPE,
		tc.COMMENTS	REMARKS
	    from ALL_TABLES at, ALL_TAB_COMMENTS tc
	    where at.OWNER = tc.OWNER
	    and at.TABLE_NAME = tc.TABLE_NAME
	    and at.OWNER <> 'SYS' and at.OWNER <> 'SYSTEM'
	    order by tc.TABLE_TYPE, at.OWNER, at.TABLE_NAME
	") or return undef;
	$sth->execute or return undef;
	$sth;
    }

    sub type_info_all {
	my ($dbh) = @_;
	my $names = {
          TYPE_NAME		=> 0,
          DATA_TYPE		=> 1,
          COLUMN_SIZE		=> 2,
          LITERAL_PREFIX	=> 3,
          LITERAL_SUFFIX	=> 4,
          CREATE_PARAMS		=> 5,
          NULLABLE		=> 6,
          CASE_SENSITIVE	=> 7,
          SEARCHABLE		=> 8,
          UNSIGNED_ATTRIBUTE	=> 9,
          FIXED_PREC_SCALE	=>10,
          AUTO_UNIQUE_VALUE	=>11,
          LOCAL_TYPE_NAME	=>12,
          MINIMUM_SCALE		=>13,
          MAXIMUM_SCALE		=>14,
        };
	# Based on the values from Oracle 8.0.4 ODBC driver
	my $ti = [
	  $names,
          [ 'LONG RAW', -4, '2147483647', '\'', '\'', undef, 1, '0', '0',
            undef, '0', undef, undef, undef, undef
          ],
          [ 'RAW', -3, 255, '\'', '\'', 'max length', 1, '0', 3,
            undef, '0', undef, undef, undef, undef
          ],
          [ 'LONG', -1, '2147483647', '\'', '\'', undef, 1, 1, '0',
            undef, '0', undef, undef, undef, undef
          ],
          [ 'CHAR', 1, 255, '\'', '\'', 'max length', 1, 1, 3,
            undef, '0', '0', undef, undef, undef
          ],
          [ 'NUMBER', 3, 38, undef, undef, 'precision,scale', 1, '0', 3,
            '0', '0', '0', undef, '0', 38
          ],
          [ 'DOUBLE', 8, 15, undef, undef, undef, 1, '0', 3,
            '0', '0', '0', undef, undef, undef
          ],
          [ 'DATE', 11, 19, '\'', '\'', undef, 1, '0', 3,
            undef, '0', '0', undef, '0', '0'
          ],
          [ 'VARCHAR2', 12, 2000, '\'', '\'', 'max length', 1, 1, 3,
            undef, '0', '0', undef, undef, undef
          ]
        ];
	return $ti;
    }

    sub plsql_errstr {
	# original version thanks to Bob Menteer
	my $sth = shift->prepare_cached(q{
	    select line,position,text from user_errors order by sequence
	});
	return undef unless $sth;
	$sth->execute or return undef;
	my (@msg, $line,$pos,$text);
	while(($line,$pos,$text) = $sth->fetchrow){
	    push @msg, "Error in PL/SQL block" unless @msg;
	    push @msg, "$line.$pos: $text";
	}
	join("\n", @msg);
    }

    #
    # note, dbms_output must be enabled prior to usage
    #
    sub dbms_output_enable {
	my ($dbh, $buffersize) = @_;
	$buffersize ||= 20000;	# use oracle 7.x default
	$dbh->do("begin dbms_output.enable(:1); end;", undef, $buffersize);
    }

    sub dbms_output_get {
	my $dbh = shift;
	my $sth = $dbh->prepare_cached("begin dbms_output.get_line(:l, :s); end;")
		or return;
	my ($line, $status, @lines);
	# line can be greater that 255 (e.g. 7 byte date is expanded on output)
	$sth->bind_param_inout(':l', \$line,  400);
	$sth->bind_param_inout(':s', \$status, 20);
	if (!wantarray) {
	    $sth->execute or return undef;
	    return $line if $status eq '0';
	    return undef;
	}
	push @lines, $line while($sth->execute && $status eq '0');
	return @lines;
    }

    sub dbms_output_put {
	my $dbh = shift;
	my $sth = $dbh->prepare_cached("begin dbms_output.put_line(:1); end;")
		or return;
	my $line;
	foreach $line (@_) {
	    $sth->execute($line) or return;
	}
	return 1;
    }

 
    sub dbms_msgpipe_get {
	my $dbh = shift;
	my $sth = $dbh->prepare_cached(q{
	    begin dbms_msgpipe.get_request(:returnpipe, :proc, :param); end;
	}) or return;
	my $msg = ['','',''];
	$sth->bind_param_inout(":returnpipe", \$msg->[0],   30);
	$sth->bind_param_inout(":proc",       \$msg->[1],   30);
	$sth->bind_param_inout(":param",      \$msg->[2], 4000);
	$sth->execute or return undef;
	return $msg;
    }

    sub dbms_msgpipe_ack {
	my $dbh = shift;
	my $msg = shift;
	my $sth = $dbh->prepare_cached(q{
	    begin dbms_msgpipe.acknowledge(:returnpipe, :errormsg, :param); end;
	}) or return;
	$sth->bind_param_inout(":returnpipe", \$msg->[0],   30);
	$sth->bind_param_inout(":proc",       \$msg->[1],   30);
	$sth->bind_param_inout(":param",      \$msg->[2], 4000);
	$sth->execute or return undef;
	return 1;
    }

}   # end of package DBD::Oracle::db


{   package DBD::Oracle::st; # ====== STATEMENT ======

    # all done in XS
}

1;

__END__

=head1 NAME

DBD::Oracle - Oracle database driver for the DBI module

=head1 SYNOPSIS

  use DBI;

  $dbh = DBI->connect("dbi:Oracle:$dbname", $user, $passwd);

  # See the DBI module documentation for full details

  # for some advanced uses you may need Oracle type values:
  use DBD::Oracle qw(:ora_types);


=head1 DESCRIPTION

DBD::Oracle is a Perl module which works with the DBI module to provide
access to Oracle databases (both version 7 and 8).

=head1 CONNECTING TO ORACLE

This is a topic which often causes problems. Mainly due to Oracle's many
and sometimes complex ways of specifying and connecting to databases.
(James Taylor and Lane Sharman have contributed much of the text in
this section.)

=head2 Oracle environment variables

Oracle typically uses two environment variables to specify default
connections: ORACLE_SID and TWO_TASK.

ORACLE_SID is really unnecessary to set since TWO_TASK provides the
same functionality in addition to allowing remote connections.

  % setenv TWO_TASK T:hostname:ORACLE_SID            # for csh shell
  $ TWO_TASK=T:hostname:ORACLE_SID export TWO_TASK   # for sh shell

  % sqlplus username/password

Note that if you have *both* local and remote databases, and you
have ORACLE_SID *and* TWO_TASK set, and you don't specify a fully
qualified connect string on the command line, TWO_TASK takes precedence
over ORACLE_SID (i.e. you get connected to remote system).

  TWO_TASK=P:sid

will use the pipe driver for local connections using SQL*Net v1.

  TWO_TASK=T:machine:sid

will use TCP/IP (or D for DECNET, etc.) for remote SQL*Net v1 connection.

  TWO_TASK=dbname

will use the info stored in the SQL*Net v2 F<tnsnames.ora>
configuration file for local or remote connections.

The ORACLE_HOME environment variable should be set correctly. It can be
left unset if you aren't using any of Oracle's executables, but it is
not recommended and error messages may not display.

Discouraging the use of ORACLE_SID makes it easier on the users to see
what is going on. (It's unfortunate that TWO_TASK couldn't be renamed,
since it makes no sense to the end user, and doesn't have the ORACLE
prefix).

=head2 Connection Examples Using DBD::Oracle

Below are various ways of connecting to an oracle database using
SQL*Net 1.x and SQL*Net 2.x.  "Machine" is the computer the database is
running on, "SID" is the SID of the database, "DB" is the SQL*Net 2.x
connection descriptor for the database.

B<Note:> Some of these formats may not work with Oracle 8.

  BEGIN {
     $ENV{ORACLE_HOME} = '/home/oracle/product/7.x.x';
     $ENV{TWO_TASK}    = 'DB';
  }
  $dbh = DBI->connect('dbi:Oracle:','scott', 'tiger');
  #  - or -
  $dbh = DBI->connect('dbi:Oracle:','scott/tiger');

works for SQL*Net 2.x, so does

  $ENV{TWO_TASK}    = 'T:Machine:SID';

for SQL*Net 1.x connections.  For local connections you can use the
pipe driver:

  $ENV{TWO_TASK}    = 'P:SID';

Here are some variations (not setting TWO_TASK)

  $dbh = DBI->connect('dbi:Oracle:T:Machine:SID','username','password')

  $dbh = DBI->connect('dbi:Oracle:','username@T:Machine:SID','password')

  $dbh = DBI->connect('dbi:Oracle:','username@DB','password')

  $dbh = DBI->connect('dbi:Oracle:DB','username','password')

  $dbh = DBI->connect('dbi:Oracle:DB','username/password','')

  $dbh = DBI->connect('dbi:Oracle:', q{scott/tiger@(DESCRIPTION=
  (ADDRESS=(PROTOCOL=TCP)(HOST= foobar)(PORT=1521))
  (CONNECT_DATA=(SID=foobarSID)))}, "")

If you are having problems with login taking a long time (>10 secs say)
then you might have tripped up on an Oracle bug. Yoy can try using one
of the ...@DB variants as a workaround. E.g.,

  $dbh = DBI->connect('','username/password@DB','');

On the other hand, that may cause you to trip up on another Oracle bug
that causes alternating connection attempts to fail! (In reality only
a small proportion of people experience these problems.)


=head2 Optimizing Oracle's listner

[By Lane Sharman <lane@bienlogic.com>] I spent a LOT of time optimizing
listener.ora and I am including it here for anyone to benefit from. My
connections over tnslistener on the same humble Netra 1 take an average
of 10-20 milli seconds according to tnsping. If anyone knows how to
make it better, please let me know!

 LISTENER =
  (ADDRESS_LIST =
        (ADDRESS =
          (PROTOCOL = TCP)
          (Host = aa.bbb.cc.d)
          (Port = 1521)
					(QUEUESIZE=10)
        )
  )

 STARTUP_WAIT_TIME_LISTENER = 0
 CONNECT_TIMEOUT_LISTENER = 10
 TRACE_LEVEL_LISTENER = OFF
 SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (SID_NAME = xxxx)
      (ORACLE_HOME = /xxx/local/oracle7-3)
			(PRESPAWN_MAX = 40)
			(PRESPAWN_LIST=
				(PRESPAWN_DESC=(PROTOCOL=tcp) (POOL_SIZE=40) (TIMEOUT=120))
			)
    )
  )

1) When the application is co-located on the host AND there is no need for
outside SQLNet connectivity, stop the listener. You do not need it. Get
your application/cgi/whatever working using pipes and shared memory. I am
convinced that this is one of the connection bugs (sockets over the same
machine). Note the $ENV{ORAPIPES} env var.  The essential code to do
this at the end of this section.

2) Be careful in how you implement the multi-threaded server. Currently I
am not using it in the initxxxx.ora file but will be doing some more testing.

3) Be sure to create user rollback segments and use them; do not use the
system rollback segments; however, you must also create a small rollback
space for the system as well.

5) Use large tuning settings and get lots of RAM. Check out all the
parameters you can set in v$parameters because there are quite a few not
documented you may to set in your initxxx.ora file.

6) Use svrmgrl to control oracle from the command line. Write lots of small
SQL scripts to get at V$ info.

  use DBI;
  # Environmental variables used by Oracle
  $ENV{ORACLE_SID}   = "xxx";
  $ENV{ORACLE_HOME}  = "/opt/oracle7";
  $ENV{EPC_DISABLED} = "TRUE";
  $ENV{ORAPIPES} = "V2";
  my $dbname = "xxx";
  my $dbuser = "xxx";
  my $dbpass = "xxx";
  my $dbh = DBI->connect("dbi:Oracle:$dbname", $dbuser, $dbpass)
             || die "Unale to connect to $dbname: $DBI::errstr\n";

=head2 Oracle utilities

If you are still having problems connecting then the Oracle adapters
utility may offer some help. Run these two commands:

  $ORACLE_HOME/bin/adapters
  $ORACLE_HOME/bin/adapters $ORACLE_HOME/bin/sqlplus

and check the output. The "Protocol Adapters" section should be the
same.  It should include at least "IPC Protocol Adapter" and "TCP/IP
Protocol Adapter".

If it generates any errors which look relevant then please talk to yor
Oracle technical support (and not the dbi-users mailing list). Thanks.
Thanks to Mark Dedlow for this information.


=head1 International NLS / 8-bit text issues

If 8-bit text is returned as '?' characters or can't be inserted
make sure the following environment vaiables are set correctly:
    NLS_LANG, ORA_NLS, ORA_NLS32, ORA_NLS33
Thanks to Robin Langdon <robin@igis.se> for this information.
Example:
   $ENV{NLS_LANG}  = "american_america.we8iso8859p1";
   $ENV{ORA_NLS}   = "$ENV{ORACLE_HOME}/ocommon/nls/admin/data";

Also From: Yngvi Thor Sigurjonsson <yngvi@hagkaup.is>
If you are using 8-bit characters and "export" for backups make sure
that you have NLS_LANG set when export is run.  Otherwise you might get
unusable backups with ? replacing all your beloved characters. We were
lucky once when we noticed that our exports were damaged before
disaster struck.

Remember that the database has to be created with an 8-bit character set.

Also note that the NLS files $ORACLE_HOME/ocommon/nls/admin/data
changed extension (from .d to .nlb) between 7.2.3 and 7.3.2.


=head1 PL/SQL Examples

These PL/SQL examples come from: Eric Bartley <bartley@cc.purdue.edu>.

  # we assume this package already exists
  my $plsql = q{

    CREATE OR REPLACE PACKAGE plsql_example
    IS
      PROCEDURE proc_np;

      PROCEDURE proc_in (
          err_code IN NUMBER
      );

      PROCEDURE proc_in_inout (
          test_num IN NUMBER,
          is_odd IN OUT NUMBER
      );

      FUNCTION func_np
        RETURN VARCHAR2;

    END plsql_example;

    CREATE OR REPLACE PACKAGE BODY plsql_example
    IS
      PROCEDURE proc_np
      IS
        whoami VARCHAR2(20) := NULL;
      BEGIN
        SELECT USER INTO whoami FROM DUAL;
      END;

      PROCEDURE proc_in (
        err_code IN NUMBER
      )
      IS
      BEGIN
        RAISE_APPLICATION_ERROR(err_code, 'This is a test.');
      END;

      PROCEDURE proc_in_inout (
        test_num IN NUMBER,
        is_odd IN OUT NUMBER
      )
      IS
      BEGIN
        is_odd := MOD(test_num, 2);
      END;

      FUNCTION func_np
        RETURN VARCHAR2
      IS
        ret_val VARCHAR2(20);
      BEGIN
        SELECT USER INTO ret_val FROM DUAL;
        RETURN ret_val;
      END;

    END plsql_example;
  };

  use DBI;

  my($db, $csr, $ret_val);

  $db = DBI->connect('dbi:Oracle:database','user','password')
        or die "Unable to connect: $DBI::errstr";

  # So we don't have to check every DBI call we set RaiseError.
  # See the DBI docs now if you're not familiar with RaiseError.
  $db->{RaiseError} = 1;

  # Example 1
  #
  # Calling a PLSQL procedure that takes no parameters. This shows you the
  # basic's of what you need to execute a PLSQL procedure. Just wrap your
  # procedure call in a BEGIN END; block just like you'd do in SQL*Plus.
  #
  # p.s. If you've used SQL*Plus's exec command all it does is wrap the
  #      command in a BEGIN END; block for you.

  $csr = $db->prepare(q{
    BEGIN
      PLSQL_EXAMPLE.PROC_NP;
    END;
  });
  $csr->execute;


  # Example 2
  #
  # Now we call a procedure that has 1 IN parameter. Here we use bind_param
  # to bind out parameter to the prepared statement just like you might
  # do for an INSERT, UPDATE, DELETE, or SELECT statement.
  #
  # I could have used positional placeholders (e.g. :1, :2, etc.) or
  # ODBC style placeholders (e.g. ?), but I prefer Oracle's named
  # placeholders (but few DBI drivers support them so they're not portable).

  my $err_code = -20001;

  $csr = $db->prepare(q{
  	BEGIN
  	    PLSQL_EXAMPLE.PROC_IN(:err_code);
  	END;
  });

  $csr->bind_param(":err_code", $err_code);

  # PROC_IN will RAISE_APPLICATION_ERROR which will cause the execute to 'fail'.
  # Because we set RaiseError, the DBI will croak (die) so we catch that with eval.
  eval {
    $csr->execute;
  };
  print 'After proc_in: $@=',"'$@', errstr=$DBI::errstr, ret_val=$ret_val\n";


  # Example 3
  #
  # Building on the last example, I've added 1 IN OUT parameter. We still
  # use a placeholders in the call to prepare, the difference is that
  # we now call bind_param_inout to bind the value to the place holder.
  #
  # Note that the third parameter to bind_param_inout is the maximum size
  # of the variable. You normally make this slightly larger than necessary.
  # But note that the perl variable will have that much memory assigned to
  # it even if the actual value returned is shorter.

  my $test_num = 5;
  my $is_odd;

  $csr = $db->prepare(q{
  	BEGIN
  	    PLSQL_EXAMPLE.PROC_IN_INOUT(:test_num, :is_odd);
  	END;
  });

  # The value of $test_num is _copied_ here
  $csr->bind_param(":test_num", $test_num);

  $csr->bind_param_inout(":is_odd", \$is_odd, 1);

  # The execute will automagically update the value of $is_odd
  $csr->execute;

  print "$test_num is ", ($is_odd) ? "odd - ok" : "even - error!", "\n";


  # Example 4
  #
  # What about the return value of a PLSQL function? Well treat it the same
  # as you would a call to a function from SQL*Plus. We add a placeholder
  # for the return value and bind it with a call to bind_param_inout so
  # we can access it's value after execute.

  my $whoami = "";

  $csr = $db->prepare(q{
  	BEGIN
  	    :whoami := PLSQL_EXAMPLE.FUNC_NP;
  	END;
  });

  $csr->bind_param_inout(":whoami", \$whoami, 20);
  $csr->execute;
  print "Your database user name is $whoami\n";

  $db->disconnect;

You can find more examples in the t/plsql.t file in the DBD::Oracle
source directory.


=head1 Using DBD::Oracle with Oracle 8 - Features and Issues

DBD::Oracle version 0.55 onwards can be built to use either the Oracle 7
or Oracle 8 OCI (Oracle Call Interface) API functions. The new Oracle 8
API is used by default and offers several advantages, including support
for LOB types and cursor binding. Here's a quote from the Oracle OCI
documentation:

  The Oracle8 OCI has several enhancements to improve application
  performance and scalability. Application performance has been improved
  by reducing the number of client to server round trips required and
  scalability improvements have been facilitated by reducing the amount
  of state information that needs to be retained on the server side.

=head2 Prepare postponed till execute

The DBD::Oracle module will avoid an explicit 'describe' operation
prior to the execution of the statement unless the application requests
information about the results (such as $sth->{NAME}). This reduces
communication with the server and increases performance. However, it also
means that SQL errors are not detected until C<execute()> is called
(instead of C<prepare()> as now).

=head2 Handling LOBs

When fetching LOBs, they are treated just like LONGs and are subject to
$sth->{LongReadLen} and $sth->{LongTruncOk}. Note that with OCI 7
DBD::Oracle pre-allocates the whole buffer (LongReadLen) before
constructing the returned column.  With OCI 8 it grows the buffer to
the amount needed for the largest LOB to be fetched so far.

When inserting or updating LOBs some I<major> magic has to be performed
behind the scenes to make it transparent.  Basically the driver has to
refetch the newly inserted 'LOB Locators' before being able to write to
them.  However, it works, and I've made it as fast as possible, just
one extra server-round-trip per insert or update after the first.
For the time being, only single-row LOB updates are supported. Also
passing LOBS to PL/SQL blocks doesn't work.

To insert or update a large LOB, DBD::Oracle has to know in advance
that it is a LOB type. So you need to say:

  $sth->bind_param($field_num, $lob_value, { ora_type => ORA_CLOB });

The ORA_CLOB and ORA_BLOB constants can be imported using

  use DBD::Oracle qw(:ora_types);

or just use the corresponding integer values (112 and 113).

To make scripts work with both Oracle7 and Oracle8, the Oracle7
DBD::Oracle will treat the LOB ora_types as LONGs without error.
So in any code you may have now that looks like

  $sth->bind_param($idx, $value, { ora_type => 8 });

you could change the 8 (LONG type) to ORA_CLOB or ORA_BLOB
(112 or 113).

One further wrinkle: for inserts and updates of LOBs, DBD::Oracle has
to be able to tell which parameters relate to which table fields.
In all cases where it can possibly work it out for itself, it does,
however, if there are multiple LOB fields of the same type in the table
then you need to tell it which field each LOB param relates to:

  $sth->bind_param($idx, $value, { ora_type=>ORA_CLOB, ora_field=>'foo' });

=head2 Binding Cursors

Cursors can now be returned from PL/SQL blocks. Either from stored
procedures or from direct C<OPEN> statements, as show below:

  use DBI;
  use DBD::Oracle qw(:ora_types);
  $dbh = DBI->connect(...);
  $sth1 = $dbh->prepare(q{
      BEGIN OPEN :cursor FOR
          SELECT table_name, tablespace_name
          FROM user_tables WHERE tablespace_name = :space
      END;
  });
  $sth1->bind_param(":space", "USERS");
  my $sth2;
  $sth1->bind_param_inout(":cursor", \$sth2, 0, { ora_type => ORA_RSET } );
  $sth1->execute();
  # $sth2 is now a valid DBI statement handle for the cursor
  while ( @row = $sth2->fetchrow_array ) { ... }

The only special requirement is the use of C<bind_param_inout()> with an
attribute hash parameter that specifies C<ora_type> as C<ORA_RSET>.
If you don't do that you'll get an error from the C<execute()> like:
"ORA-06550: line X, column Y: PLS-00306: wrong number or types of
arguments in call to ...".

=head1 Oracle Related Links

=head2 Oracle on Linux

  http://www.datamgmt.com/maillist.html
  http://www.eGroups.com/list/oracle-on-linux
  http://www.wmd.de/wmd/staff/pauck/misc/oracle_on_linux.html
  ftp://oracle-ftp.oracle.com/server/patch_sets/LINUX

=head2 Free Oracle Tools and Links

  ora_explain supplied and installed with DBD::Oracle.

  http://vonnieda.org/oracletool/

=head2 Commercial Oracle Tools and Links

Assorted tools and references for general information.
No recommendation implied.

  http://www.platinum.com/products/oracle.htm
  http://www.SoftTreeTech.com
  http://www.databasegroup.com

Also PL/Vision from RevealNet and Steven Feuerstein, and
"Q" from Savant Corporation.


=head1 SEE ALSO

L<DBI>

=head1 AUTHOR

DBD::Oracle by Tim Bunce. DBI by Tim Bunce.

=head1 COPYRIGHT

The DBD::Oracle module is Copyright (c) 1995,1996,1997,1998,1999 Tim Bunce. England.
The DBD::Oracle module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself with the exception that it
cannot be placed on a CD-ROM or similar media for commercial distribution
without the prior approval of the author.

=head1 ACKNOWLEDGEMENTS

A great many people have helped me over the years. Far too many to
name, but I thank them all.

See also L<DBI/ACKNOWLEDGEMENTS>.

=cut
