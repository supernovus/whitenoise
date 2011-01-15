## White Noise: A static site generator.
## Designed for huri.net, but usable elsewhere.

use v6;

class WhiteNoise;

use JSON::Tiny;
use Exemel;
use Flower;
use File::Mkdir;

has $!flower;
has $.config;
has %!cache;
has %!plugins;

submethod BUILD (:$conf!) {
  if $conf.IO !~~ :f { die "missing configuration file"; }
  my $text = slurp($conf);
  my $json = from-json($text);
  ## A quick sanity test.
  if ($json !~~ Hash) { die "$conf must be a JSON object definition."; }
  if (!$json.exists('templates')) {
    die "$conf is missing the 'templates' definitions.";
  }
  if (!$json.exists('output')) { die "$conf is missing output folder."; }
  if (!$json.exists('site')) { warn "$conf is missing 'site' definition."; }
  ## Okay, we passed the test, let's finish up here.
  $!config := $json;
}

## The main routine that starts this process.
method generate ($file) {
  if $file.IO !~~ :f { say "skipping invalid file '$file'..."; return; }
  say "Processing '$file': ";
  my %page = self!get-page($file);
  my $pagecontent = self!parse-page(%page);
  my $outfile = $!config<output> ~ self!page-path(%page);
  self!output-file($outfile, $pagecontent);
  if (%page<data>.exists('parent')) {
    self!generate-story(%page);
  }
  else {
    self!generate-indexes(%page);
  }
}

## Build indexes
method !generate-indexes (%page) {
  print " - Generating indexes... ";
  say "skipped, not implemented yet.";
}

## Build stories
method !generate-story (%page) {
  print " - Generating story... ";
  say "skipped, not implemented yet.";
}

## Take a file, get the content and the metadata from it.
method !get-page ($file) {
  print " - Loading '$file'... ";
  my $text = slurp($file);
  my $xml = Exemel::Element.parse($text);
  my $metadata = {};
  ## Let's find the metadata.
  loop (my $i=0; $i < $xml.nodes.elems; $i++) {
    if $xml.nodes[$i] !~~ Exemel::Element { next; }
    my $id = $xml.nodes[$i].attribs<id>;
    if $id && $id eq 'metadata' {
      my $md_node = $xml.nodes[$i].nodes[0];
      if $md_node ~~ Exemel::Text {
        my $mdtext = ~$md_node;
        $metadata = from-json($mdtext);
      }
      $xml.nodes.splice($i, 1);
    }
  }
  my %page = {
    'file' => $file,
    'xml' => $xml,
    'data' => $metadata,
  };
  say "done.";
  return %page;
}

## Parse a page contents using our own reference system
## and then throwing it through Flower.
## Expects the %page hash as returned by get-page.
method !parse-page (%page is rw) {
  my @plugins;
  if ($!config.exists('plugins')) {
    @plugins.push: |$!config<plugins>;
  }
  if (%page<data>.exists('plugins')) {
    @plugins.push: |%page<data><plugins>;
  }
  for @plugins -> $module {
    print " - Calling '$module' plugin... ";
    my $plugin = self!load-plugin($module);
    $plugin.parse(%page);
    say "done.";
  }

  my $metadata = %page<data>;
  my $type = 'article';
  if (%page.exists('type')) {
    $type = %page<type>;
  }

  ## make "page/content" into the XML nodes, if this is a true page.
  if (%page.exists('xml')) {
    $metadata<content> = %page<xml>.nodes;
  }

  print " - Parsing template... ";
  ## Let's get the template, and generate the page itself.
  my $template = $!config<templates>{$type};
  if (defined($!flower)) {
    $!flower.=another(:file($template));
  }
  else {
    $!flower = Flower.new(:file($template));
    if $!config<templates>.exists('plugins') {
      my @modifiers = $!config<templates><plugins>;
      for @modifiers -> $modifier {
        print "loading $modifier, ";
      }
      $!flower.load-modifiers(|@modifiers);
    }
  }
  my $sitedata = {};
  if ($!config.exists('site')) {
    $sitedata = $!config<site>;
  }
  my %parsedata = {
    :site($sitedata),
    :page($metadata),
  };
  my $pagecontent = $!flower.parse(|%parsedata);
  say "done.";
  return $pagecontent;
}

## Spit out a file.
method !output-file ($file, $content) {
  my $fh = open $file, :w;
  $fh.say: $content;
  $fh.close;
  say " - Generated page: '$file'.";
}

## Create output folders.
method !make-output-path ($folder) { 
  mkdir $!config<output> ~ $folder, :p;
}

## Paths for pages (articles and story chapters.)
method !page-path (%page) {
  my $file = %page<file>;
  my $opts = %page<data>;
  if (%!cache.exists($file)) {
    return %!cache{$file};
  }
  my @filepath = $file.subst(/\/$/, '').split('/');
  my $filename = @filepath[@filepath.end];
  $filename ~~ s:g/\.xml$//;
  my $dir;
  if ($opts.exists('parent')) { 
    $dir = 'stories/' ~ $opts<parent>; 
  }
  else {
    $dir = 'articles';
    if ($opts.exists('changelog')) { # Please put changelog in newest first.
      my $cl = $opts<changelog>;
      my $last = $cl[$cl.end];
      my $date = $last<date>;
      my $dt;
      if ($date ~~ /^\d+$/) {
        $dt = DateTime.new(+$date);
      }
      else {
        $dt = DateTime.new(~$date);
      }
      my $year = $dt.year;
      my $month = '%02d'.sprintf($dt.month);
      $dir ~= '/' ~ $year ~ '/' ~ $month;
    }
  }
  my $folder = '/' ~ $dir;
  self!make-output-path($folder);
  my $outpath = $folder ~ '/' ~ $filename ~ '.html';
  %!cache{$file} = $outpath;
  return $outpath;
}

## Paths for indexes
method !index-path ($tag='', $page=1) {
  my $dir = '/';
  if ($tag) {
    $dir = "/tags/$tag/";
  }
  elsif ($page > 1) {
    $dir = '/index/';
  }
  self!make-output-path($dir);
  my $file = 'index.html';
  if ($page > 1) {
    $file = "page$page.html";
  }
  my $outpath = $dir ~ $file;
  return $outpath;
}

## The path for the story table of contents.
method !story-path ($file) {
  if (%!cache.exists($file)) {
    return %!cache{$file};
  }
  my @filepath = $file.subst(/\/$/, '').split('/');
  my $filename = @filepath[@filepath.end];
  $filename ~~ s:g/\.xml$//;

  my $folder = '/stories/' ~ $filename;
  self!make-output-path($folder);
  my $outpath = $folder ~ '/index.html';
  %!cache{$file} = $outpath;
  return $outpath;
}

## Cache path for indexes
method !index-cache ($tag='default') {
  my $dir = './cache/indexes';
  if ($!config.exists('indexes') && $!config<indexes>.exists('folder')) {
    $dir = $!config<indexes><folder>;
  }
  mkdir $dir, :p;
  return $dir ~ '/' ~ "$tag.json";
}

## Cache path for stories
method !story-cache ($file) {
  if (%!cache.exists("story::$file")) {
    return %!cache{"story::$file"};
  }
  my @filepath = $file.subst(/\/$/, '').split('/');
  my $filename = @filepath[@filepath.end];
  $filename ~~ s:g/\.xml$//;

  my $dir = './cache/stories';
  if ($!config.exists('stories') && $!config<stories>.exists('folder')) {
    $dir = $!config<stories><folder>;
  }
  mkdir $dir, :p;
  my $cachedir = $dir ~ '/' ~ "$filename.json";
  %!cache{"story::$file"} = $cachedir;
  return $cachedir;
}

## Page Plugins, oh joy, oh joy.
method !load-plugin ($name) {
  if (%!plugins.exists($name)) {
    return %!plugins{$name};
  }
  my $module = $name;
  if $module !~~ /'::'/ {
    $module = "WhiteNoise::$module";
  }
  eval("use $module");
  if defined $! { die "loading plugin failed: $!"; }
  my $plugin = eval($module~'.new()');
  if defined $! { die "initializing plugin failed: $!"; }
  $plugin.engine = self; ## We need a reference to ourself.
  %!plugins{$name} = $plugin;
  return $plugin;
}

## That's all folks.

