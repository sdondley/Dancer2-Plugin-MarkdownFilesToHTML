use strict;
use warnings;
use File::Path;
use Data::Dumper qw(Dumper);
use Test::More;
use Test::Most tests => 10;
use Test::NoWarnings;

BEGIN {
  $ENV{'DANCER_ENVIRONMENT'} = 'testing';
}

use Plack::Test;
use HTTP::Request::Common;

{ package TestApp;
  use Dancer2;
  use Dancer2::Plugin::MarkdownFilesToHTML;
  use Data::Dumper qw(Dumper);

  get '/' =>   sub { return template 'index' };
  get '/intro' => sub {
    my $html = mdfile_2html('intro.md');
    template 'index.tt', {
      html => $html,
    },
  };

  get '/all_tut_files' => sub {
    my $html = mdfiles_2html('dzil_tutorial');
    template 'index.tt', {
      html => $html,
    },
  };

  get '/get_toc' => sub {
    my ($html, $toc) = mdfiles_2html('dzil_tutorial', {generate_toc => 1});
    template 'index.tt', {
      html => $html,
      toc => $toc
    },
  };

}

my $test = Plack::Test->create( TestApp->to_app );
my $res = $test->request( GET '/' );
ok( $res->is_success, 'Non-plugin get request can be made' );

$res = $test->request( GET 'dzil_tutorial' );
ok( $res->is_success, 'Can load page using basic config file' );
like ($res->content, qr/<li>Beginning developers/, 'gets content');

$res = $test->request( GET 'intro' );
ok( $res->is_success, 'mdfile_2html call works');
like ($res->content, qr/In the Beginning/, 'gets content');

$res = $test->request( GET 'all_tut_files' );
ok( $res->is_success, 'mdfiles_2html call works');
like ($res->content, qr/<li>Beginning developers/, 'gets content');

$res = $test->request( GET 'get_toc' );
ok( $res->is_success, 'passed option works');
like ($res->content, qr/href="#header_0_aprereqs"/, 'generates toc');

clean_cache_dir();

sub clean_cache_dir {
  rmtree 'xt/data/markdown_files/cache';
  mkdir  'xt/data/markdown_files/cache' or die "Unable to make cache directory\n";
}

#like( $res->content, qr/function load_js.*<\/head>/s, 'Added fallback function to head' );
#like( $res->content, qr/jquery-1.11.*<\/head>/s, 'Added jquery library to head' );
#like( $res->content, qr/<body>.*jquery.growl/s, 'Added growler library to body' );
