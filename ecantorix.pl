#!/usr/bin/perl

use strict;
use warnings;
use MIDI;
use MIDI::Opus;
use Math::FFT;
use Cwd;

our $ESPEAK_ATTEMPTS = 8;
our $ESPEAK_TRANSPOSE = -24;
our $ESPEAK_PITCH_MIN = 0;
our $ESPEAK_PITCH_START = 50;
our $ESPEAK_PITCH_MAX = 99;
our $ESPEAK_SPEED_MIN = 80;
our $ESPEAK_SPEED_START = 175;
our $ESPEAK_SPEED_MAX = 450;
our $ESPEAK = 'espeak -z -p "$PITCH" -s "$SPEED" -w "$OUT" -m "<prosody range=\"0\">$SYLLABLE</prosody>"';
our $SOX_RATE = 22050;
our $SOX_PROCESS_IN_TO_S16LE = 'sox "$IN" -t raw -r "$RATE" -e signed -b 16 -c 1 - remix - silence 1 1s 0 reverse silence 1 1s 0 reverse';
our $SOX_PROCESS_TEMPO_PITCHBEND_S16LE_TO_OUT = 'sox -t raw -r "$RATE" -e signed -b 16 -c 1 - "$OUT" tempo -s "$TEMPO" $PITCHBEND';
our $PITCHBEND_DURATION = 0.05;
our $ANALYZE_MINFREQ = 20;
our $ANALYZE_MAXFREQ = 1000;

my ($filename) = @ARGV;
my $opus = MIDI::Opus->new({from_file => $filename});
my $tracks = $opus->tracks_r();

sub abstime(@)
{
	my $t = 0;
	return map {
		[$_->[0], $t += $_->[1], @{$_}[2..(@$_-1)]];
	} @_;
}

sub reltime(@)
{
	my $t = 0;
	return map {
		my $tsave = $t;
		$t = $_->[1];
		[$_->[0], $t - $tsave, @{$_}[2..(@$_-1)]];
	} @_;
}

sub tick2lmms($)
{
	return int(48 / $opus->ticks() * $_[0] + 0.5);
}

sub getpitch($$$)
{
	my ($data, $mi, $ma) = @_;

	# pad for autocorrelation to work
	my $n = @$data;
	my $n2 = $n;
	--$n2;
	$n2 |= $n2 >> 16;
	$n2 |= $n2 >> 8;
	$n2 |= $n2 >> 4;
	$n2 |= $n2 >> 2;
	$n2 |= $n2 >> 1;
	++$n2;
	my @data = (@$data, (0) x (2 * $n2 - $n));
	my $fft = new Math::FFT(\@data);
	my $correl = $fft->correl($fft);
	my $best = $mi;
	my $bestscore = 0;
	die "WTF: $ma >= @{[@$correl / 2]}"
		if $ma >= @$correl / 2;
	for($mi .. $ma)
	{
		my $s = $correl->[$_];
		if($s > $bestscore)
		{
			$best = $_;
			$bestscore = $s;
		}
	}
	my $sf = 0;
	my $s = 0;
	for($best-2 .. $best+2)
	{
		$s += $correl->[$_];
		$sf += $_ * $correl->[$_];
	}
	return $sf / $s;
}

sub play_note($$$$$$$)
{
	my ($tick, $dtick, $t, $dt, $note, $pitchbend, $syllable) = @_;

	# iterative find fitting -p (pitch, 0..99) and -s (speed, 80..450)
	# parameters for espeak

	$syllable =~ s/^\///g;
	$syllable =~ s/^\\//g;

	my $pitchbend_str = "";
	my $pitchbend_t = 0;
	for(@$pitchbend)
	{
		my ($start, $end, $semitones) = @$_;
		my $delay = $start - $pitchbend_t;
		my $duration = $end - $start;
		my $cents = $semitones * 100;
		$pitchbend_str .= " $delay,$cents,$duration";
	}
	$pitchbend_str = "bend $pitchbend_str"
		if length $pitchbend_str;

	my $hz = 440 * 2**(($note - 69 + $ESPEAK_TRANSPOSE) / 12);
	my $pitch = $ESPEAK_PITCH_START;
	my $speed = $ESPEAK_SPEED_START;

	my $outname = sprintf "%s/note_%4.2f_%d_%s_%s.wav",
		getcwd(), $dt, $note, $pitchbend_str, $syllable;

	if(!-f $outname)
	{
		print STDERR "Rendering $outname...\n";
		my $thisdt;
		my $thishz;
		my $data;
		for(1..$ESPEAK_ATTEMPTS)
		{
			local $ENV{OUT} = "out.wav";
			local $ENV{PITCH} = $pitch;
			local $ENV{SPEED} = $speed;
			local $ENV{SYLLABLE} = $syllable;
			0 == system $ESPEAK
				or die "$ESPEAK: $! $?";
			local $ENV{RATE} = $SOX_RATE;
			local $ENV{IN} = "out.wav";
			open my $fh, '-|', $SOX_PROCESS_IN_TO_S16LE
				or die "$SOX_PROCESS_IN_TO_S16LE: $!";
			$data = do { undef local $/; <$fh>; };
			close $fh
				or die "$SOX_PROCESS_IN_TO_S16LE: $! $?";
			die "$SOX_PROCESS_IN_TO_S16LE: No data"
				unless length $data;

			my @data = unpack "s*", $data;
			$thisdt = @data / $SOX_RATE;
			$thishz = $SOX_RATE / getpitch(\@data, $SOX_RATE / $ANALYZE_MAXFREQ, $SOX_RATE / $ANALYZE_MINFREQ);

			$speed = [sort { $a <=> $b } (
				$ESPEAK_SPEED_MIN,
				int($speed * $thisdt / $dt + 0.5),
				$ESPEAK_SPEED_MAX)]->[1];
			$pitch = [sort { $a <=> $b } (
				$ESPEAK_PITCH_MIN,
				int($pitch * $hz / $thishz + 0.5),
				$ESPEAK_PITCH_MAX)]->[1];
		}

		my $pitchfix = $hz / $thishz;
		my $lengthfix = $dt / $thisdt;
		print STDERR "Pitch correction: $thishz -> $hz\n";
		print STDERR "Length correction: $thisdt -> $dt\n";
		my $rate0 = $SOX_RATE;

		my $tempofix = 1 / $lengthfix;
		my $rate = int(0.5 + $rate0 * $pitchfix);
		$tempofix *= $rate0 / $rate;;

		local $ENV{RATE} = $rate;
		local $ENV{TEMPO} = $tempofix;
		local $ENV{OUT} = $outname;
		local $ENV{PITCHBEND} = $pitchbend_str;
		open my $fh, '|-', $SOX_PROCESS_TEMPO_PITCHBEND_S16LE_TO_OUT
			or die "$SOX_PROCESS_TEMPO_PITCHBEND_S16LE_TO_OUT: $!";
		print $fh $data;
		close $fh
			or die "$SOX_PROCESS_TEMPO_PITCHBEND_S16LE_TO_OUT: $! $?";
	}

	my $lmms_tick = tick2lmms($tick);
	my $lmms_dtick = tick2lmms($tick + $dtick) - $lmms_tick;
	print <<EOF;
		<sampletco muted="0" pos="$lmms_tick" len="$lmms_dtick" src="$outname" />
EOF
}

# we store tempo as seconds per tick
my @tempi = map {
	$_->[0] eq 'set_tempo'
		? ([$_->[1], $_->[2] * 0.000001 / $opus->ticks()])
		: ();
} abstime $opus->tracks_r()->[0]->events();
sub tick2sec($)
{
	my ($tick) = @_;
	my $sec = 0;
	my $curtempo = [0, 0.5 / $opus->ticks()];
	for(@tempi)
	{
		if($_->[0] < $tick)
		{
			# this event is in the past
			# we add the full time since the last one then
			$sec += ($_->[0] - $curtempo->[0]) * $curtempo->[1];
		}
		else
		{
			# if this event is in the future, we break
			last;
		}
		$curtempo = $_;
	}
	$sec += ($tick - $curtempo->[0]) * $curtempo->[1];
	return $sec;
};

my $totallen = 0;
for my $trackno(0..@$tracks-1)
{
	print STDERR "Processing track $trackno...\n";
	my $track = $tracks->[$trackno];
	my @events = abstime $track->events();
	$totallen = $events[-1][1]
		if @events and $events[-1][1] > $totallen;;
}
my $lmms_totallen = tick2lmms $totallen;

print <<EOF;
<?xml version="1.0"?>
<!DOCTYPE multimedia-project>
<multimedia-project version="1.0" creator="Linux MultiMedia Studio (LMMS)" creatorversion="0.4.13" type="song">
	<head timesig_numerator="4" mastervol="100" timesig_denominator="4" masterpitch="0">
		<bpm value="120" id="3481048"/>
	</head>
	<song>
		<trackcontainer width="600" x="5" y="5" maximized="0" height="300" visible="1" type="song" minimized="0">
			<track muted="0" type="5" name="Automation track">
				<automationtrack/>
				<automationpattern name="Tempo" pos="0" len="$lmms_totallen">
EOF
for(@tempi)
{
	my $lmms_tick = tick2lmms($_->[0]);
	# x [sec/tick]
	# x/60 [min/tick]
	# 60/x [tick/min]
	# (60/$opus->ticks())/x [quarter/min]
	my $lmms_tempo = int((60 / $opus->ticks()) / $_->[1] + 0.5);
	print <<EOF;
					<time value="$lmms_tempo" pos="$lmms_tick"/>
EOF
}
print <<EOF;
					<object id="3481048"/>
				</automationpattern>
			</track>
			<track muted="0" type="2" name="Sample track">
				<sampletrack vol="100">
					<fxchain numofeffects="0" enabled="0"/>
				</sampletrack>
EOF

for my $trackno(0..@$tracks-1)
{
	print STDERR "Processing track $trackno...\n";
	my $track = $tracks->[$trackno];

	my @events = abstime $track->events();

	# lyrics = array of [starttick, text, channels]
	# channels = hash of channel => notes
	# notes = array of [starttick, ticks, pitch]
	my @lyrics = map {
		$_->[0] =~ /^lyrics$|^text_event$/ ? [$_->[1], $_->[2], {}] : ()
	} @events;
	my $insert_note = sub
	{
		my ($starttick, $ticks, $channel, $pitch) = @_;
		my $found = undef;
		for(@lyrics)
		{
			if($_->[0] <= $starttick)
			{
				$found = $_;
			}
		}
		if($found)
		{
			push @{$found->[2]{$channel}},
				[$starttick, $ticks, $pitch];
			return 1;
		}
		else
		{
			return undef;
		}
	};

	my @notes = ();
	my %notehash;
	for(@events)
	{
		$_->[0] = 'note_off' if $_->[0] eq 'note_on' and $_->[4] == 0;
		next
			if $_->[0] ne 'note_on' and $_->[0] ne 'note_off';
		my $time = $_->[1];
		my $channel = $_->[2];
		my $pitch = $_->[3];
		if($_->[0] eq 'note_on')
		{
			if(exists $notehash{$channel}{$pitch})
			{
				warn "note_already_on: $time/$channel/$pitch";
				next;
			}
			$notehash{$channel}{$pitch} = $time;
		}
		else
		{
			if(!exists $notehash{$channel}{$pitch})
			{
				warn "Spurious note_off: $time/$channel/$pitch";
				next;
			}
			my $starttime = $notehash{$channel}{$pitch};
			delete $notehash{$channel}{$pitch};

			$insert_note->(
				$starttime, $time - $starttime,
				$channel, $pitch)
				or warn "No lyrics found for note: $starttime/$time/$channel/$pitch";
		}
	}

	for(@lyrics)
	{
		my ($starttick, $text, $channels) = @$_;
		for my $channel(sort keys %$channels)
		{
			my $notes = $channels->{$channel};
			my $firstpitch = $notes->[0]->[2];
			my $realstarttick = $notes->[0]->[0];
			my $realendtick = $notes->[-1]->[0] + $notes->[-1]->[1];
			my $realstarttime = tick2sec $realstarttick;
			my $realendtime = tick2sec $realendtick;
			my @pitchbend = ();
			my $lastnoteendtime = undef;
			for(@$notes)
			{
				my ($notestarttick, $noteticks, $pitch) = @$_;
				my $noteendtick = $notestarttick + $noteticks;
				my $notestarttime = tick2sec($notestarttick);
				my $noteendtime = tick2sec($noteendtick);
				if(defined $lastnoteendtime)
				{
					push @pitchbend, [
						$lastnoteendtime - $realstarttime,
						$notestarttime - $realstarttime,
						$pitch - $firstpitch];
				}
				$lastnoteendtime = $noteendtime;
			}
			play_note
				$realstarttick,
				$realendtick - $realstarttick,
				$realstarttime,
				$realendtime - $realstarttime,
				$firstpitch, \@pitchbend, $text;
		}
	}
}

print <<EOF;
			</track>
		</trackcontainer>
	</song>
</multimedia-project>
EOF