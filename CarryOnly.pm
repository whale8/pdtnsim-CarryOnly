#!/usr/bin/env perl
#
# Agent class for single-copy and carry-only routing.
# Copyright (c) 2011-2015, Hiroyuki Ohsaki.
# All rights reserved.
#
# $Id: CarryOnly.pm,v 1.11 2015/12/11 08:14:04 ohsaki Exp $
#

package DTN::Agent::CarryOnly;

use Carp;
use List::Util qw(max);
use Smart::Comments;
use diagnostics;
use strict;
use warnings;
use Class::Accessor::Lite (
    rw => [
        qw(id range mobility last_neighbors received receive_queue delivered
            tx_count rx_count dup_count changed_mobility scheduler monitor)
    ]
);

my $MAX_RANGE = 200;

# create and initialize the object
sub new {
    my ( $class, $opts_ref ) = @_;

    croak "Mobility class must be specified.\n"
        unless ( defined $opts_ref->{mobility} );
    croak "Scheduler class must be specified.\n"
        unless ( defined $opts_ref->{scheduler} );
    croak "Monitor class must be specified.\n"
        unless ( defined $opts_ref->{monitor} );

    my $nagents = $opts_ref->{scheduler}->agents();
    $opts_ref->{id} //= $nagents + 1;
    $opts_ref->{range} //= 50;
    my $self = {%$opts_ref};
    bless $self, $class;

    croak "range cannot exceed \$MAX_RANGE ($MAX_RANGE)\n"
        if ( $self->range() > $MAX_RANGE );
    $self->last_neighbors( [] );
    $self->received(      {} );
    $self->receive_queue( {} );
    $self->delivered(     {} );
    $self->tx_count(0);
    $self->rx_count(0);
    $self->dup_count(0);
    $self->changed_mobility(0);

    $self->scheduler()->add_agent($self);
    return $self;
}

sub msg_src {
    my ( $self, $msg ) = @_;

    return ( split '-', $msg )[0];
}

sub msg_dst {
    my ( $self, $msg ) = @_;

    return ( split '-', $msg )[1];
}

sub msg_id {
    my ( $self, $msg ) = @_;

    return ( split '-', $msg )[2];
}

# return the zone corresponding the geometry @$POS
sub zone {
    my ( $self, $x, $y ) = @_;

    $x //= $self->mobility()->current()->[0];
    $y //= $self->mobility()->current()->[1];
    my $i = max( 0, int( $x / $MAX_RANGE ) );
    my $j = max( 0, int( $y / $MAX_RANGE ) );
    return ( $i, $j );
}

sub cache_zone {
    my ($self) = @_;

    my ( $i, $j ) = $self->zone();
    push @{ $self->scheduler()->zone_cache()->[$j]->[$i] }, $self;
}

# find neighbor nodes within the communication range
sub neighbors {
    my ($self) = @_;

    croak "update_zone() must have been called for creating zone database.\n"
        unless ( defined $self->scheduler()->zone_cache() );

    my $p = $self->mobility()->current();
    my ( $i, $j ) = $self->zone();
    my $range = $self->range();
    my @neighbors;
    # check nine zones surrounding the current one
    for my $dj ( -1, 0, 1 ) {
        next if ( $j + $dj < 0 );
        for my $di ( -1, 0, 1 ) {
            next if ( $i + $di < 0 );
            for my $agent (
                @{  $self->scheduler()->zone_cache()->[ $j + $dj ]
                        ->[ $i + $di ]
                }
                )
            {
                next if ( $agent eq $self );
                my $q = $agent->mobility()->current();
                next if abs( $p->[0] - $q->[0] ) > $range;
                next if abs( $p->[1] - $q->[1] ) > $range;
                next if ( abs( $p - $q ) > $range );
                push @neighbors, $agent;
            }
        }
    }
    return @neighbors;
}

# find encouter nodes (i.e., newly visible nodes)
sub encounters {
    my ($self) = @_;

    my @neighbors = $self->neighbors();
    my %encounters = map { $_->id() => $_ } @neighbors;
    for my $agent ( @{ $self->last_neighbors() } ) {
        delete $encounters{ $agent->id() };
    }
    $self->last_neighbors( \@neighbors );
    return values %encounters;
}

# send a message to the specified agent
sub sendmsg {
    my ( $self, $agent, $msg ) = @_;

    $agent->recvmsg( $self, $msg );
    $self->tx_count( $self->tx_count() + 1 );
    $self->monitor()->display_forward( $self, $agent, $msg );
    $self->monitor()->change_agent_status($self);
}

# receive a message from the specified agent
sub recvmsg {
    my ( $self, $agent, $msg ) = @_;

    # received message is temporally stored in the reception queue
    $self->receive_queue()->{$msg}++;
    $self->rx_count( $self->rx_count() + 1 );
    if ( defined $self->received()->{$msg} ) {
        $self->dup_count( $self->dup_count() + 1 );
    }
    $self->monitor()->change_agent_status($self);
}

sub messages {
    my ($self) = @_;

    return grep { $self->received()->{$_} > 0 } keys %{ $self->received() };
}

# return all messages need to be delivered
sub pending_messages {
    my ($self) = @_;

    return grep {
        $self->msg_dst($_) != $self->id()
            and !defined $self->delivered()->{$_}
    } $self->messages();
}

sub accepted_messages {
    my ($self) = @_;

    return grep { $self->msg_dst($_) == $self->id() } $self->messages();
}

sub forward {
    my ($self) = @_;

    my @encounters = $self->encounters();
    for my $agent (@encounters) {
        for my $msg ( $self->pending_messages() ) {
            # forward carrying messages only to the destination
            my $dst = $self->msg_dst($msg);
            next unless ( $agent->id() == $dst );
            $self->sendmsg( $agent, $msg );
            $self->received()->{$msg}--;
            $self->delivered()->{$msg}++;
        }
    }
}

# advance the simulation for a delta time
sub advance {
    my ($self) = @_;

    $self->mobility()->move( $self->scheduler()->delta() );
    $self->monitor()->move_agent($self);
    $self->forward();
}

# merge received messages in the queue into the list
sub flush {
    my ($self) = @_;

    for my $msg ( keys %{ $self->receive_queue() } ) {
        $self->received()->{$msg} += $self->receive_queue()->{$msg};
        delete $self->receive_queue()->{$msg};
    }
}

1;
