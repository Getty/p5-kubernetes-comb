package Kubernetes::Comb::Static;
# ABSTRACT: A Comb whose manifests are .pk8s and YAML files
our $VERSION = '0.001';

use Moo;
extends 'Kubernetes::Comb';
with 'Kubernetes::Comb::Role::Static';

use Carp qw( croak );
use namespace::autoclean;

=synopsis

  package MyApp::Comb::GeoIP;
  use Moo;
  extends 'Kubernetes::Comb::Static';

  use File::ShareDir qw( dist_dir );

  sub endpoints      { { name => 'http', port => 8080 } }
  sub manifest_dir   { dist_dir('MyApp-Combs') }
  sub manifest_files { 'geoip.yaml', 'geoip-cron.pk8s' }

=description

A L<Kubernetes::Comb> whose L<Kubernetes::Comb/manifests> come from files, by
L<Kubernetes::Comb::Role::Static>. A subclass names the files with
C<manifest_files> and where relative ones are with C<manifest_dir>;
everything else of the contract is the one of L<Kubernetes::Comb>.

For the stub of an existing Comb class -- which has to extend that class --
compose L<Kubernetes::Comb::Role::Static> instead.

=cut

sub manifest_files {
  my ( $self ) = @_;
  croak ref($self).' has no manifest files: override manifest_files';
}

=method manifest_files

Dies: a subclass overrides it with its list of files, see
L<Kubernetes::Comb::Role::Static/manifest_files>.

=seealso

=over

=item * L<Kubernetes::Comb::Role::Static>

=item * L<Kubernetes::Comb>

=back

=cut

1;
