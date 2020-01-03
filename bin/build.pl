#!/usr/bin/env perl
use strict;
use warnings;
use 5.010;

use Data::Dumper;
use File::Path qw/ make_path /;
use Getopt::Long;
use Term::ANSIColor qw/ colored /;

use FindBin '$Bin';
use lib "$Bin/../local/lib/perl5";
use YAML::PP;

my $container_home = '/tmp/home';
my $cachedir = "$Bin/../.cache";
my $prefix = 'yamlrun';

GetOptions(
    'help|h' => \my $help,
);

if ($help) {
    usage();
    exit;
}


my ($task, $library) = @ARGV;

my $yp = YAML::PP->new( schema => [qw/ JSON Merge /] );
my ($libs) = $yp->load_file("$Bin/../list.yaml");

my $libraries = $libs->{libraries};
my $runtimes = $libs->{runtimes};

if ($task eq 'list') {
    my $output = list_libraries();
    say $output;
}
elsif ($task eq 'update-readme') {
    my $output = list_libraries();
    my $readme = "$Bin/../README.md";
    open my $fh, '<', $readme or die $!;
    my $lines = do { local $/; <$fh> };
    close $fh;
    $lines =~ s/^(\| ID).*\|\n\n/$output\n/s;
    open $fh, '>', $readme or die $!;
    print $fh $lines;
    close $fh;
}
elsif ($task eq 'list-images') {
    list_images();
}
elsif ($task eq 'build') {
    if ($library) {
        my $lib = $libraries->{ $library }
            or die "Library $library not found";
        build($library);
    }
}
elsif ($task eq 'fetch-sources') {
    if ($library) {
        source($library);
    }
    else {
        for my $library (sort keys %$libraries) {
            source($library);
        }
    }
}

sub list_libraries {
    my $output = '';
    my $format = "| %-17s | %-10s | %-18s | %-8s | %-7s |\n";
    $output .= sprintf $format,
        qw/ ID Language Name Version Runtime /;
    $output .= sprintf $format, '-'x17, '-'x10, '-'x18, '-'x8, '-'x7;
    for my $id (sort keys %$libraries) {
        my $lib = $libraries->{ $id };
        $output .= sprintf $format,
            $id, @$lib{qw/ lang name version runtime /};
    }
    return $output;
}

sub list_images {
    my $cmd = qq,docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}\t{{.Size}}" "$prefix/runtime-*",;
    my @lines = qx{$cmd};
    my @image_fields = qw/ image tag id created size /;
    my %images;
    make_path $cachedir;
    for my $line (@lines) {
        chomp $line;
        my %info;
        @info{ @image_fields } = split m/\t/, $line;
        $images{ $info{image} } = \%info;
    }
    for my $item (@$runtimes) {
        my $runtime = $item->{runtime};
        my $image = "$prefix/runtime-$runtime";
        my $info = $images{ $image };
        my $fmt_image = "%-25s | %-5s | %-12s | %s | %s";
        my $fmt = "%2s %-17s %-20s %-10s %-7s | %-8s";
        if ($info) {
            say colored (['grey12 bold'], sprintf $fmt_image, @$info{ @image_fields });
        }
        else {
            say colored (['grey12 bold'], sprintf $fmt_image, $image, ('-') x 4);
            say sprintf $fmt, ('') x 6;
            next;
        }

        my %installed = info_from_image($info->{id}, $info->{image});
        $info->{installed} = \%installed;

        my @libraries = keys %$libraries;
        $runtime ne 'all' and @libraries = grep {
            $info->{image} eq "$prefix/runtime-$libraries->{ $_ }->{runtime}"
        } @libraries;
        for my $name (sort { $a cmp $b } @libraries) {
            my $lib = $libraries->{ $name };
            my $installed = $info->{installed}->{ $name };
            say sprintf $fmt,
                '', $name, @$lib{qw/ name lang version /}, $installed->{VERSION} // '-';
        }
        say sprintf $fmt, ('') x 6;
    }
    return;
}

sub info_from_image {
    my ($id, $image) = @_;
    my $infofile = "$cachedir/$id-info.yaml";
    my @docs;
    if (-e $infofile) {
        @docs = $yp->load_file($infofile);
    }
    else {
        my $cmd = "docker run -i --rm -v$Bin/../docker/global:/utils '$image' /utils/info.sh";
#        say "# $cmd";
        my $out = qx{$cmd};
        return if $?;
        @docs = $yp->load_string($out);
        $yp->dump_file($infofile, @docs);
    }
    my %installed;
    for my $doc (@docs) {
        next unless $doc;
        $installed{ $doc->{ID} } = $doc;
    }
    return %installed;
}

sub build {
    my ($library) = @_;
    say "Building $library";
    source($library);
    my $lib = $libraries->{ $library }
        or die "Library $library not found";
    my $buildscript = $lib->{'build-script'};
    unless ($buildscript) {
        warn "No build-script for $library";
    }
    my $name = $lib->{name}
        or die "No name for $library";
    my $version = $lib->{'version'}
        or die "No version for $library";
    my $runtime = $lib->{'runtime'}
        or die "No runtime for $library";
    my $build_image = "builder-" . ($lib->{'build-image'} || $runtime);

    my $dir = "$Bin/../docker/$runtime";
    mkdir "$dir/build";
    my $info_file = "$dir/build/yaml/info/$library";
    if (-e $info_file) {
        my $info = YAML::PP->new->load_file($info_file);

        if ($info->{VERSION} eq $version) {
            say "$library version $version is already installed";
            return;
        }
    }

    my $ok = 1;
    if ($buildscript) {
        my $source = $lib->{'source'}
            or die "No source for $library";
        my ($filename) = $source =~ m{.*/(.*)\z};
        my $cmd = sprintf
            'docker run -it --rm --user %s'
            . ' --env HOME=%s --env VERSION=%s --env SOURCE=%s --env LIBNAME=%s'
            . ' -v%s/build:/build -v%s/utils:/buildutils -v%s/sources:/sources'
            . " $prefix/%s /buildutils/%s",
            $<,
            $container_home, $version, "/sources/$filename", $library,
            ($dir) x 3,
            $build_image, $buildscript;

        say "Building $library...";
        say "# $cmd";
        chdir $dir;
        my $rc = system $cmd;
        $ok = $rc ? 0 : 1;
    }
    if ($ok) {
        say "ok, built $library $version";
        make_path "$dir/build/yaml/info";
        my $source = $lib->{source} // '';
        my $homepage = $lib->{homepage} // '-';
        my $lang = $lib->{lang} // '-';
        open my $fh, '>', $info_file or die $!;
        print $fh <<"EOM";
---
ID: $library
NAME: $name
VERSION: '$version'
SOURCE: $source
HOMEPAGE: $homepage
LANG: $lang
EOM
        close $fh;
    }
    else {
        say "failed";
        unlink $info_file;
    }
}

sub source {
    my ($library) = @_;
    say $library;
    my $lib = $libraries->{ $library }
        or die "Library $library not found";
    my $runtime = $lib->{runtime}
        or die "No runtime for $library";
    my $source = $lib->{source}
        or return;
    my ($filename) = $source =~ m{.*/(.*)\z};
    my $srcdir = "$Bin/../docker/$runtime/sources";
    make_path $srcdir;
    chdir $srcdir;
    if (-e $filename) {
        say "$filename exists, skip";
    }
    else {
        my $cmd = "wget --no-verbose --timestamping $source";
        say $cmd;
        system $cmd;
    }
}

sub usage {
    say <<"EOM";
Usage:
    $0 build
    $0 build c-libyaml
    $0 fetch-sources
    $0 fetch-sources c-libyaml
EOM
}
