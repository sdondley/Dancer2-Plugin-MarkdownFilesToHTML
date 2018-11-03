package Dancer2::Plugin::MarkdownFileToHTML ;

use strict;
use warnings;
use Dancer2::Plugin;
use Carp;
use Encode qw( decode );
use lib '.';
use File::Spec::Functions qw(catfile);
use File::Slurper qw ( read_text );
use HTML::TreeBuilder;
use Data::Dumper 'Dumper';
use File::Basename;
use Storable;
use Dancer2::Plugin::MarkdownParser;

plugin_keywords qw( mdfile_2html mdfiles_2html );
# builds the routes from config file
#
sub BUILD {
  my $s = shift;
  my $app = $s->app;
  my $config = $s->config;

  # add routes from config file
  my $routes = $config->{routes};
  foreach my $route (@$routes) {
    if (ref $route) {
      my ($path) = keys %$route;
      my $options = _set_options($route, $path, $config,
                        qw( file_root route_root template layout header_class generate_toc
                        linkable_headers cache dialect exclude_files include_files
                        markdown_extensions));

      if ($route->{$path}{dir}) {
        my $dir = File::Spec->catfile($options->{file_root}, $route->{$path}{dir});
        $s->_add_route($path, $dir, 'mdfiles_2html', $options);
      } elsif ($route->{$path}{file}) {
        my $file = File::Spec->catfile($options->{file_root}, $route->{$path}{file});
        $s->_add_route($path, $file, 'mdfile_2html', $options);
      } else {
        carp "No file or directory associated with path: $path";
      }
    } else {
      carp "Route does not have a file or directory associated with it";
    }
  }
}

# helper function for setting options
sub _set_options {
  my ($route, $path, $config, @options) = @_;

  my %defaults = (route_root => '', template => 'index.tt', layout => 'main.tt',
                  header_class => '', generate_toc => 0, linkable_headers => 0,
                  cache => 1, dialect => 'GitHub', exclude_files => '',
                  include_files => '', markdown_extensions => '',
                  file_root => 'lib/data/markdown_files');

  my %options = ();
  foreach my $option (@options) {
    $options{$option} = $route->{$path}{$option} 
                      || $config->{defaults}{$option}
                      || $defaults{$option};
  }
  if ($options{genereate_toc}) {
    $options{linkable_headers} = 1;
  }
  if ($options{root_route}) {
    $options{root_route} .= '/';
  }
  return \%options;
}


# helper function for adding a route
sub _add_route {
  my ($s, $path, $resource, $method, $options) = @_;

  my ($html, $toc) = '';
  $s->app->add_route(
    method => 'get',
    regexp => '/' . $options->{route_root} . "$path",
    code => sub {
      my $app = shift;
      ($html, $toc) = $s->$method($resource, $options);
      $app->template($options->{template}, { html => $html, toc => $toc });
    },
  );
}

# gathers lists of files in a directory to send them off for
# parsing or cache retrieval
sub mdfiles_2html {
  my $s = shift;
  my $dir = shift;
  my $options = shift;

  my $html = '';
  my $toc = '';

  # gather the files according the options supplied
  my @files = ();
  if ($options->{include_files}) {
    my @files = map { File::Spec->catfile($dir, $_) } @{$options->{include_files}};
  } else {
    opendir my $d, $dir or die "Cannot open directory: $!";
    @files = grep { $_ !~ /^\./ } readdir $d;
    closedir $d;
    if ($options->{markdown_extensions}) {
      my @matching_files = ();
      foreach my $md_ext (@{$options->{markdown_extensions}}) {
        push @matching_files, grep { $_ =~ /\.$md_ext$/ } @files;  
      }
      @files = @matching_files;
    }
  }
  if ($options->{exclude_files}) {
    foreach my $excluded_file (@{$options->{exclude_files}}) {
      @files = grep { $_ ne $excluded_file } @files;
    }
  }

  foreach my $file (sort @files) {
    my ($content, $toc_file) = $s->mdfile_2html(File::Spec->catfile($dir, $file), $options);
    $html .= $content;
    $toc .= $toc_file
  }
  return ($html, $toc);
}

# The workhorse function of this module which sends the markdown file to get
# parsed or retrieves html version from cache. Also generates the table of
# contents
# TODO: make the TOC generation optional based on config setting
sub mdfile_2html {
	my $s        = shift;
  my $file     = shift;
  my $options  = shift;
  my $has_toc = $options->{generate_toc};

  # check the cache for a hit by comparing timestemps of cached file and
  # markdown file
  my $cache_file = $file =~ s/\///gr;
  $cache_file = "lib/data/markdown_files/cache/$cache_file";
  if (-f $cache_file && $options->{cache}) {
    if (-M $cache_file eq -M $file) {
      my $data = retrieve $cache_file;
      if ($data->{linkable_headers} == $options->{linkable_headers}
          && $data->{generate_toc}  == $options->{generate_toc}) {
        return ($data->{html}, $data->{toc});
      }
    }
  }

  # no cache hit so we must parse the file
  
  # direct filehandle to a string instead of a file
  my $out = q{};
  open my $fh, '>:encoding(UTF-8)', \$out;

  my $h = Dancer2::Plugin::MarkdownParser->new(
    output => $fh,
    linkable_headers => $options->{linkable_headers},
    header_class => $options->{header_class},
    dialect => $options->{dialect},
  );

  my $markdown = read_text($file);
  $h->parse(\$markdown);
  close $fh;

  if (!$options->{linkable_headers}  && !$options->{generate_toc}) {
    return $out;
  }


  # generate the TOC and modify header ids so they are linkable
  my $tree = HTML::TreeBuilder->new_from_content(decode ('UTF-8', $out));
  my @elements = $tree->look_down(id => qr/^header/);
  my ($base)   = fileparse($file, qr/\.[^.]*/);
  my $toc = '';
  if ($options->{linkable_headers} && !$options->{generate_toc}) {
    foreach my $element (@elements) { 
      my $id = $element->attr('id');
      $element->attr('id', $id . "_$base");
    }
  } else {
    $toc = HTML::TreeBuilder->new();
    foreach my $element (@elements) { 
      my $id = $element->attr('id');
      $element->attr('id', $id . "_$base");
      my $toc_link = HTML::Element->new('a', href=> "#${id}_$base");
      $id =~ s/^(header_\d+)_.*/$1/;
      $toc_link->attr('class', $id);
      my $br = HTML::Element->new('br');
      $toc_link->push_content($element->as_text);
      $toc->push_content($toc_link);
      $toc->push_content($br);
    }
  }

  # generate the HTML from trees
  # guts method gets rid of <html> and <body> tags added by TreeBuilder 
  # regex hack needed because markdent does not handle strikethroughs
  my $struck_tree = $tree->guts->as_HTML =~ s/~~(.*?)~~/<strike>$1<\/strike>/gsr;
  my $struck_toc  = $toc->guts->as_HTML  =~ s/~~(.*?)~~/<strike>$1<\/strike>/gsr if $toc;

  # store the data for caching. set timestamp of cached file to timestamp of
  # original file
  if ($options->{cache}) { 
    store { html => $struck_tree, toc => $struck_toc,
            linkable_headers => $options->{linkable_headers},
            generate_toc => $options->{generate_toc} },
          $cache_file;
    my ($read, $write) = (stat($file))[8,9];
    utime($read, $write, $cache_file);
  }

  return ($struck_tree, $struck_toc);
}

1;
