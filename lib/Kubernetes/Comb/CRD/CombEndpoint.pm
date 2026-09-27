package Kubernetes::Comb::CRD::CombEndpoint;
# ABSTRACT: One resolved endpoint in the status of a Comb custom resource
our $VERSION = '0.001';

use IO::K8s::Resource;

=description

An entry of C<status.endpoints> of a L<Kubernetes::Comb::CRD::Comb>. A Comb
publishes its endpoints already resolved -- redirected when an upstream is
active -- so a Comb borrowing from this one needs no knowledge of the layers
behind it. In Perl code the value object is L<Kubernetes::Comb::Endpoint>;
L<Kubernetes::Comb::Endpoint/to_crd> and L<Kubernetes::Comb::Endpoint/from_crd>
convert.

=cut

k8s name => Str, { required => 1 };

=attr name

Required. Endpoint name as the Comb class declares it, e.g. C<client>.

=cut

k8s protocol => Str;

=attr protocol

C<tcp>, C<udp>, ...

=cut

k8s port => Int, { required => 1 };

=attr port

Required. The port the endpoint is offered on.

=cut

k8s cluster => Str;

=attr cluster

Address inside the cluster, C<host:port>, e.g. C<nats.platform.svc:4222>.

=cut

k8s external => Str;

=attr external

Address from outside the cluster, C<host:port>.

=seealso

=over

=item * L<Kubernetes::Comb::Endpoint>

=item * L<Kubernetes::Comb::CRD::CombStatus>

=back

=cut

1;
