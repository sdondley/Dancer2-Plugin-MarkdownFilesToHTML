package Dancer2::Plugin::MarkdownFilesToHTML ;

# ABSTRACT: Easy conversion of markdown documents to HTML for display in your Dancer2 website
use 5.010; use strict; use warnings;

use Carp;
use Encode                qw( decode );
use Storable;
use File::Path            qw(make_path);
use Data::Dumper          'Dumper';
use File::Basename;
use Dancer2::Plugin;
use HTML::TreeBuilder;
use File::Spec::Functions qw(catfile);
use Text::Markdown::Hoedown;

plugin_keywords qw( md2html );

has options             => (is => 'rw', default => sub { {} });
has cache               => (is => 'ro', from_config => 'defaults.cache',               default => sub { 1 } );
has layout              => (is => 'ro', from_config => 'defaults.layout',              default => sub { 'main.tt' } );
has template            => (is => 'ro', from_config => 'defaults.template',            default => sub { 'index.tt' } );
has file_root           => (is => 'ro', from_config => 'defaults.file_root',           default => sub { 'lib/data/markdown_files' } );
has route_root          => (is => 'ro', from_config => 'defaults.route_root',          default => sub { '' } );
has header_class        => (is => 'ro', from_config => 'defaults.header_class',        default => sub { '' } );
has generate_toc        => (is => 'ro', from_config => 'defaults.generate_toc',        default => sub { 0  } );
has exclude_files       => (is => 'ro', from_config => 'defaults.exclude_files',       default => sub { [] } );
has include_files       => (is => 'ro', from_config => 'defaults.include_files',       default => sub { [] } );
has linkable_headers    => (is => 'ro', from_config => 'defaults.linkable_headers',    default => sub { 0  } );
has markdown_extensions => (is => 'ro', from_config => 'defaults.markdown_extensions', default => sub { [] } );

# Builds the routes from config file
sub BUILD {
  my $s      = shift;
  my $app    = $s->app;
  my $config = $s->config;

  # add routes from config file
  foreach my $route (@{$config->{routes}}) {

    # validate arguments supplied from config file
    if ((ref $route) ne 'HASH') {
      die 'Config file misconfigured. Check syntax or consult documentation.';
    }

    $s->_set_options($route);

    # Do the route addin'

    my %options = %{$s->options};
    $s->app->add_route(
      method => 'get',
      regexp => '/' . $options{route_root} . $options{path},
      code => sub {
        my $app = shift;
        my ($html, $toc) = $s->md2html($options{resource}, \%options);
        $app->template($options{template},
                      { html => $html, toc => $toc },
                      { layout => $options{layout} });
      },
    );
  }
}

sub _set_options {
  my $s = shift;
  my $options = shift;

  my @settings = qw(
    cache layout template file_root route_root header_class generate_toc
    exclude_files include_files linkable_headers markdown_extensions );

  my ($path) = keys %$options;
  my $defaults = $s->config->{defaults};
  my $local_options = (ref $options->{$path}) ? $options->{$path} : $options;
  my %options = (%$defaults, %$local_options);

  foreach my $setting (@settings) {
    $options{$setting} = $options->{$setting} //= $s->$setting;
  }

  $options{set} = 1;
  $options{path}             = $path;
  $options{route_root}       .= '/' if $options{route_root};
  $options{linkable_headers} = 1   if  $options{generate_toc};

  my $is_abs = File::Spec->file_name_is_absolute($options{resource});
  if (!$is_abs) {
    $options{resource} = File::Spec->catfile($options{file_root}, $options{resource});
  }

  $s->options(\%options);

}

# Keyword for generating HTML from a markdown resource (file or directory)
# either through cache retrieval or parsing of the resource
sub md2html {
  my ($s, $resource, $options) = @_;

  # If keyword called directly, options won't be set yet
  if (!$options->{set}) {
    $options->{resource} = $resource;
    $s->_set_options($options);
  } else {
    $s->options($options);
  }

  if (!-e $s->options->{resource}) {
    my $return = 'This route is not properly configured. Resource: '
                  . $s->options->{resource} . ' does not exist on the server.';
    $s->options({});
    return wantarray ?  ($return, '') : $return;
  }

  my $html = '';
  my $toc = '';

  my @files = ();
  if (-f $s->options->{resource}) {
    push @files, $s->options->{resource};
  } else {
    my $dir = $s->options->{resource};
    # gather the files according the options supplied
    if (@{$s->options->{include_files}}) {
      my @files = @{$s->options->{include_files}};
    } else {
      opendir my $d, $dir or die "Cannot open directory: $!";
      @files = grep { $_ !~ /^\./ } readdir $d;
      closedir $d;
      my @matching_files = ();
      foreach my $md_ext (@{$s->options->{markdown_extensions}}) {
        push @matching_files, grep { $_ =~ /\.$md_ext$/ } @files;
      }
      @files = @matching_files if @matching_files;
    }

    foreach my $excluded_file (@{$s->options->{exclude_files}}) {
      @files = grep { $_ ne $excluded_file } @files;
    }

    @files = map { File::Spec->catfile($dir, $_) } @files;
  }

  # concatenate html and toc into two strings
  foreach my $file (sort @files) {
    my ($file_html, $file_toc)  = $s->_mdfile_2html($file);
    $html                      .= $file_html;
    $toc                       .= $file_toc || '';
  }
  return wantarray ? ($html, $toc) : $html;
}

# Sends the markdown file to get parsed or retrieves html version from cache,
# if available. Also generates the table of contents.
sub _mdfile_2html {
  my $s = shift;
  my $file = shift;

  # chop off extension
  my ($base)   = fileparse($file, qr/\.[^.]*/);

  # generate the cache directory if it doesn't exist
  my $cache_dir = File::Spec->catfile(dirname($s->options->{'file_root'}), 'md_file_cache');
  if (!-d $cache_dir) {
    make_path $cache_dir or die "Cannot make cache directory $!";
  }

  # generate unique cache file name appended with values of two options
  my $cache_file = dirname($file);
  my $sep = File::Spec->catfile('', '');
  $cache_file =~ s/\Q$sep\E//g;
  $cache_file = File::Spec->catfile($cache_dir,
                 $cache_file . $base . $s->options->{linkable_headers} . $s->options->{generate_toc}
                             . $s->options->{header_class} =~ s/ //gr);

  # check for cache hit
  # TODO: Save options in separate file so they can be compared
  if (-f $cache_file && $s->options->{cache}) {
    if (-M $cache_file eq -M $file) {
      print Dumper 'cache hit: '. $file if $ENV{DANCER_ENVIRONMENT} && $ENV{DANCER_ENVIRONMENT} eq 'testing';
      my $data = retrieve $cache_file;
      return ($data->{html}, $data->{toc});
    }
  }

  # no cache hit so we parse the file
  # slurp the file and parse it with Hoedown's markdown function
  my $markdown = '';
  {
    local $/;
    open my $md, '<:encoding(UTF-8)', $file or die "Can't open $file: $!";
    $markdown = <$md>;
    close $md;
  }
  my $out  = markdown($markdown, extensions => HOEDOWN_EXT_FENCED_CODE, toc_nesting_lvl => 0);
  my $tree = HTML::TreeBuilder->new_from_content($out);

  my @code_els = $tree->find_by_tag_name('code');
  foreach my $code_el (@code_els) {
    if (!$code_el->left && !$code_el->right) {
      $code_el->attr('class' => 'single-line');
    }
  }

  # See if we can cache and return the output without further processing
  # generate_toc makes linkable_headers true so we just need to test linkable_headers option
  if (!$s->options->{linkable_headers} && !$s->options->{header_class}) {
    my $html = $tree->guts->as_HTML;
    _cache_data($cache_file, $file, $html) if $s->options->{cache};
    return ($html, '');
  }

  # generate linkable headers along with toc if option for it is set
  my @elements = $tree->look_down(_tag => qr/^h\d$/);
  my $toc      = HTML::TreeBuilder->new() if $s->options->{generate_toc};
  my $hdr_ct   = 0;
  foreach my $element (@elements) {
    my $id = 'header_' . ${hdr_ct};
    $hdr_ct++;
    $element->attr('id', $id . '_' . $base);
    $element->attr('class' => $s->options->{header_class}) if $s->options->{header_class};
    if ($s->options->{generate_toc}) {
      my ($level) = $element->tag =~ /(\d)/;
      my $toc_link = HTML::Element->new('a', href=> "#${id}_${base}", class => 'header_' . $level);
      $toc_link->push_content($element->as_text);
      $toc->push_content($toc_link);
      $toc->push_content(HTML::Element->new('br'));
    }
  }

  # Generate the final HTML from trees and cache
  # "guts" method gets rid of <html> and <body> tags added by TreeBuilder
  my ($html, $toc_out) = ($tree->guts->as_HTML, $toc ? $toc->guts->as_HTML : '');
  _cache_data($cache_file, $file, $html, $toc_out);
  return ($html, $toc_out);
}

sub _cache_data {
  my ($cache_file, $file, $content, $toc) = @_;
  $toc //= '';

  store { html => $content, toc => $toc }, $cache_file;
  my ($read, $write) = (stat($file))[8,9];
  utime($read, $write, $cache_file);
}

1;

__END__

=head1 SYNOPSIS

Include the plugin in your Dancer2 app:

  use Dancer2::Plugin::MarkdownFilesToHTML;

No other perl code is necessary. Routes can be established to display the HTML
associated with a directory of markdown documents or a single document using
the Dancer2 C<config.yml> file:

  plugins:
    MarkdownFilesToHTML:
      defaults:
        header_class: 'elegantshadow scrollspy'  # class added to headers
        route_root: 'tutorials'                  # where routes get attached to
        file_root: 'lib/data/markdown_files'     # location of markdown files
        generate_toc: 1                          # generate a table of contents
        linkable_headers: 1                      # create unique id for headers
        template: 'index.tt'                     # template file to use
        layout: 'main.tt'                        # layout file to use
      routes:                                    # list of conversion routes
        - dzil_tutorial:                         # the route to the page
            resource: 'Dist-Zilla-for-Beginners' # dir containing markdown files
            markdown_extensions:
              - md
              - mdwn
        - single_file:
            resource: 'intro.md'                 # markdown file to be converted
            template: 'doc.tt'                   # defaults can be overridden
            generate_toc: 0
            linkable_headers: 0

See the C<CONFIGURATION> section below for more details on configuration
settings.

Markdown file conversion can also be accomplished using the C<md2html> keyword,
like so:

  # convert a single markdown file to HTML
  $html = md2html('/path/to/file.md', { header_class => 'header_style' });

  # convert directory of markdown files to HTML and generate table of contents
  ($html, $toc) = md2html('/dir/with/markdown/files', { generate_toc => 1 });

=head1 DESCRIPTION

This module converts markdown files to an HTML string for output to the Dancer2
web app framework. Using the Dancer2 config file, multiple routes can be
established in the web app, with each route converting a single markdown
document or all the markdown documents in a directory to HTML. Optionally, it
can return a second HTML string containing a hierarchical table of contents
based on the contents of the markdown. The HTML will be displayed with the
templates and routes specified in Dancer2's config file. See the
L<CONFIGURATION> section for more details. To generate HTML from within your
app's code, refer to the L<KEYWORDS> section.

This module relies on the L<Text::Markdown::Hoedown> module to execute the
markdown conversions which uses a fast C module. To further enhance performance,
a caching mechanism using L<Storable> is employed for each converted markdown
file so markdown to HTML conversions are avoided except for new and updated
markdown files. See the L</"MARKDOWN CONVERSION NOTES"> for more details on the
conversion process.

=head1 CONFIGURATION

Use the Dancer2 C<config.yml> file for an easy way to associate routes with HTML
generated from converted markdown files. Unless you need to modify the the HTML
output by the module in some way, you should use the configuration file method
for generating and displaying your HTML.

Edit the C<config.yml> file, usually located in the root of your Dancer2 app,
as follows:

  plugins:
    MarkdownFiletoHTML:

Follow these two lines with your default settings:

      defaults:
        header_class: 'my_header classes here'
        route_root: 'content'
        file_root: '/lib/data/content'
        genereate_toc: 1

...and so on.

After the defaults, you can list your routes:

       routes:
         - a_web_page:
           resource: 'convert/all/files/in/this/dir/relative/to/file_root'
         - another_web_page:
           resource: '/convert/this/file/with/absolute/path.md'

Routes must have a C<resource> property that provide a file or directory path to
your markdown files. Paths can be absolute or relative. Relative paths are
appended to the path in C<file_root>.

Within each route, the default options can be overridden:

         - my_page
           resource: 'file.md'
           generate_toc: 0
           header_class: ''

Consult the L</OPTIONS> section for defaults for each of the options.

The options that apply to directories accept a list of arguments, created like
this:

          - another_page:
            resource: 'my_dir_containing_md_files'
            include_files:
              - 'file4.md'
              - 'file2.md'
              - 'file1.md'
              - 'file3.md'

Now only the four files listed get processed in the order listed above.

All of the L</OPTIONS> listed below are supported by the configuration file.

=keyword md2html($resource [ \%options ])

Converts a single markdown file or all the files in a directory into HTML.
An optional hashref can be passed with options as documented in the L</OPTIONS>
section below.

Examples:

  ($html, $toc) = md2html('/path/to/file.md',
                  { header_class => 'my_style', generate_toc +> 1 });

  $html) = md2html('/path/to/dir',
                  { header_class => 'my_style', generate_toc +> 1 });

If the C<$resource> argument is relative, it will be appended to the
C<file_root> setting in the configuration file. If C<file_root> is not set,
C<lib/data/markdown_files> is used.

If a directory of files is convereted, each file can be thought of as a chapter
within a single larger document comprised of all the individual files. Ideally,
each file will have a single level 1 header tag to serve as the title for the
chapter. All files present in a directory are markdown documents.  Hidden files
(those beginning with a '.') are automatically excluded. These defaults can be
modified.

L</"General Options"> apply to both files and directories. See the L</"Directory
Options"> section for options that let you control how files in a directory are
processed and selected.

=head1 OPTIONS

=gen_option route_root => $route

The route root is the route the individual conversion routes are attached to.
For example, if the route root is C<tutorials>, a conversion route named C<perl>
will be found at C<tutorials/perl>. If no route root is supplied, C</> is used.

=gen_option file_root => $path

The root directory where markdown files can be found. Defaults to the
C<lib/data/markdown_files> directory within the Dancer2 web app. Directories and
files supplied by each route will be relative to this path if they are relative.
If directory or file path is absolute, this value is ignored.

=gen_option generate_toc => $bool

A boolean value that defaults to false. If true, the function will return a
second string containing a table of contents with anchor tags linking to the
associated headers in the content. This setting effectively sets the
C<linkable_headers> option to true (see below).

=gen_option linkable_headers => $bool

A boolean value that defaults to false. If true, a unique id is inserted into
the header HTML tags so they can be linked to. Linkable headers are also
generated if the toc C<generate_toc> option is true.

=gen_option header_class => $classes

Accepts a string which is added to each of the header tags' "class" attribute.

=gen_option template => $template_file

The template file to use relative to directory where the app's views are store.
C<index.tt> is the default template.

=gen_option layout => $layout_file

The layout file to use relative to the app's layout directory C<main.tt> is the
default layout.

=gen_option cache => $bool

Stores generated html in files. If the timestamp of the cached file indicates
the original file been updated, a new version of page will be generated. The
cache defaults to true and there is no good reason to turn this off except to
troubleshoot problems with the cache.

=dir_option include_files => [ $file1, $file2, ... ]

An array of strings representing the files that should be converted in the order
they are to be converted.

By default, the files are processed in alphabetical order. Though alphabetical
ordering can be overridden manually using the C<include_files> option, it's
easier to use a naming convention for your files that will places them in the
desired order:

  tutorial01.md
  tutorial02.md
  tutorial03.md
  etc.

=dir_option exclude_files => [ $file1, $file2, ... ]

An array of strings represening the files that should not be converted to
HTML.

=dir_option markdown_extensions => [ $ext1, $ext2, ... ]

An array of strings representing the extensions that should be used to determine
which files contain the markdown documents. This option is valid only with the
C<mdfiles_2html>) keyword. Only files with the listed extension will be
converted.

=head1 MARKDOWN CONVERSION NOTES

The module aims to support the dialect of markdown as implemented by GitHub with
strikethroughs (C<~~strike~~>) and "fenced" code (C<```fenced code```>). This module
may make the dialect options configurable in the future.

The module will add a "single-line" class to single lines of code to facility additional styling.

The module is particarly well-suited for markdown that follows a classic outline
structure with markdown headers, like so:

  # Title of Document

  ## Header 2

  ### Header 3

  #### Header 4

  And so on...

Each header is converted to a C<<hX\>> html tag where C<X> is the level
corresponding header level in the markdown file. If present, the headers can be
used to generate the table of contents and associated anchor tags for linking to
each of the sections within the document. If headers are not present in the
markdown file, a useful table of contents cannot be generated.

=head1 DEPENDENCIES

L<Dancer2>

L<Text::Markup::Hoedown>


=head2 Development status

This module is being actively supported and
maintained. Suggestions for improvement are welcome.

=head1 SEE ALSO

L<Dancer2>

L<Text::Markup::Hoedown>
