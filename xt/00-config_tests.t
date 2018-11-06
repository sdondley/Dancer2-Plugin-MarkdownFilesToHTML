use strict;
use warnings;
use File::Path;
use Test::Most tests => 2;

BEGIN {
  $ENV{'DANCER_ENVIRONMENT'} = 'testing';
}

use Plack::Test;
use HTTP::Request::Common;

{ package TestApp;
  use Dancer2;
  use Dancer2::Plugin::MarkdownFilesToHTML;

  get '/' => sub { return template 'index' };
}

my $test = Plack::Test->create( TestApp->to_app );
my $res = $test->request( GET '/' );
ok( $res->is_success, 'Successful request' );

$res = $test->request( GET 'dzil_tutorial' );
ok( $res->is_success, 'Successful request' );

clean_cache_dir();



sub clean_cache_dir {
  rmtree 'xt/data/markdown_files/cache';
  mkdir  'xt/data/markdown_files/cache' or die "Unable to make cache directory\n";
}

#like( $res->content, qr/function load_js.*<\/head>/s, 'Added fallback function to head' );
#like( $res->content, qr/jquery-1.11.*<\/head>/s, 'Added jquery library to head' );
#like( $res->content, qr/<body>.*jquery.growl/s, 'Added growler library to body' );
