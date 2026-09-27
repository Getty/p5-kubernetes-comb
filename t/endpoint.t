use strict;
use warnings;
use Test::More;

use Kubernetes::Comb::Endpoint;
use Kubernetes::Comb::CRD::CombEndpoint;

subtest 'defaults and required attributes' => sub {
  my $ep = Kubernetes::Comb::Endpoint->new( name => 'client', port => 4222 );
  is $ep->protocol, 'tcp', 'protocol defaults to tcp';
  ok !$ep->has_cluster,  'no cluster address';
  ok !$ep->has_external, 'no external address';

  ok !eval { Kubernetes::Comb::Endpoint->new( port => 4222 ); 1 }, 'name is required';
  ok !eval { Kubernetes::Comb::Endpoint->new( name => 'client' ); 1 }, 'port is required';
  ok !eval { Kubernetes::Comb::Endpoint->new( name => 'client', port => 'four' ); 1 },
    'port is an integer';
};

subtest 'to_crd and from_crd' => sub {
  my $ep = Kubernetes::Comb::Endpoint->new(
    name     => 'client',
    protocol => 'udp',
    port     => 4222,
    cluster  => 'nats.platform.svc:4222',
    external => 'nats.example.com:4222'
  );
  my $entry = $ep->to_crd;
  isa_ok $entry, 'Kubernetes::Comb::CRD::CombEndpoint';
  is_deeply $entry->TO_JSON, {
    name     => 'client',
    protocol => 'udp',
    port     => 4222,
    cluster  => 'nats.platform.svc:4222',
    external => 'nats.example.com:4222'
  }, 'status entry carries every field';

  my $back = Kubernetes::Comb::Endpoint->from_crd($entry);
  isa_ok $back, 'Kubernetes::Comb::Endpoint';
  is_deeply { map { $_ => $back->$_ } qw( name protocol port cluster external ) },
            { map { $_ => $ep->$_ }   qw( name protocol port cluster external ) },
            'round trip keeps every field';

  my $sparse = Kubernetes::Comb::Endpoint->from_crd(
    Kubernetes::Comb::CRD::CombEndpoint->new( name => 'metrics', port => 9090 ) );
  is $sparse->protocol, 'tcp', 'missing protocol becomes tcp';
  ok !$sparse->has_cluster && !$sparse->has_external, 'missing addresses stay missing';
  is_deeply $sparse->to_crd->TO_JSON, { name => 'metrics', protocol => 'tcp', port => 9090 },
    'and are not written';
};

done_testing;
