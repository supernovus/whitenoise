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
    self!process-story(%page);
  }
  else {
    self!process-indexes(%page);
  }
}

method !load-cache ($file) {
  if $file.IO ~~ :f {
    say " *** Loading cache '$file'.";
    my $text = slurp($file);
    my $json = from-json($text);
    return $json;
  }
  else {
    say " *** Creating cache '$file'.";
    return []; # default cache, an empty array.
  }
}

method !save-cache($file, $data) {
  my $text = to-json($data);
  self!output-file($file, $text);
}

## We use the same 'add-to-list' method as indexes.
method !process-story (%page) {
  self!add-to-list(%page, 'story', %page<data><parent>);
}

## Main routine to build indexes
method !process-indexes (%page) {
  ## First, add it to the main page.
  self!add-to-list(%page);
  if %page<data>.exists('tags') {
    for @(%page<data><tags>) -> $tag {
      self!add-to-list(%page, $tag);
    }
  }
}

## Add pages to indexes or stories.
method !add-to-list (%page, $tag?, $story?) {
  my $name = 'main';
  if ($tag) { $name = $tag; }
  say "Generating $name index:";
  my $cachefile; 
  if ($story) {
    $cachefile = self!story-cache($story);
  }
  else {
    $cachefile = self!index-cache($tag);
  }
  my $cache = self!load-cache($cachefile);
  my $pagelink = self!page-path(%page);
  say " - Adding $pagelink to index...";
  if $cache.elems > 0 { ## If there are items, check for this page.
    loop (my $i=0; $i < $cache.elems; $i++) {
      if $cache[$i]<link> eq $pagelink {
        say " * Updating '$pagelink' in cache.";
        $cache.splice($i, 1);
      }
    }
  }
  my $updated = DateTime.now;
  my $snippet = %page<xml>.elements(:id<snippet>);
  if ($snippet.elems > 0) {
    $snippet = $snippet[0];
  }
  else {
    $snippet = %page<xml>.elements()[0];
  }

  my $pagedata = %page<data>.clone;
  $pagedata.delete('content');

  my $pagedef = {
    'link'      => $pagelink,
    'title'     => $pagedata<title>,
    'updated'   => ~$updated,
    'snippet'   => ~$snippet,
  };

  ## Lets add any tag links.
  if $pagedata.exists('tags') {
    my @tags;
    for @($pagedata<tags>) -> $pagetag {
      my $taglink = self!index-path(1, $pagetag);
      my $tagdef = {
        'name'   => $pagetag,
        'link'   => $taglink,
      };
      @tags.push: $tagdef;
    }
    $pagedef<tags> = @tags;
  }

  ## And now, for some magic tricks.
  ## If your templates need extra fields from the
  ## page data, you can include a field called
  ## 'index' which is an array of data fields to include.
  if $pagedata.exists('index') {
    for @($pagedata<index>) -> $section {
      if ($section == 'link' | 'title' | 'updated' | 'snippet' | 'tags') {
        ## Skip any sections that we shouldn't be overriding.
        next;
      }
      if $pagedata.exists($section) {
        $pagedef{$section} = $pagedata{$section};
      }
    }
  }

  if ($story) {
    $cache.push: $pagedef;
  }
  else {
    $cache.unshift: $pagedef;
  }

  self!save-cache($cachefile, $cache);

  ## Now, let's build the index pages.
  if ($story) {
    self!build-story($cache, $story);
  }
  else {
    self!build-index(1, $cache, $tag);
  }

}

## Build index pages
method !build-index ($page, $index, $tag?, $pagelimit?) {
  my $perpage;
  if $pagelimit { $perpage = $pagelimit; }
  elsif ($!config.exists('indexes') && $!config<indexes>.exists('perpage')) {
    $perpage = $!config<indexes><perpage>;
  }
  else {
    $perpage = 10;
  }
  my $from = ($perpage * $page) - $perpage;
  my $to   = ($perpage * $page) - 1;
#say " ** from $from to $to **";
  if $to > $index.end { $to = $index.end; }
#say " -- from $from to $to --";
  my $pages = ($index.elems / $perpage).ceiling;
  my @items = $index[ $from .. $to ];
  my @pager = [ 1 .. $pages ];
  my $pager = [];
  for @pager -> $pagecount {
    my $pagelink = self!index-path($pagecount, $tag);
    my $current = False;
    if ($pagecount == $page) {
      $current = True;
    }
    my $pagerdef = {
      'num'     => $pagecount,
      'link'    => $pagelink,
      'current' => $current,
    };
    $pager.push($pagerdef);
  }

  my %pagedef = {
    'type' => 'index',
    'data' => {
      'count'    => $pages,
      'current'  => $page,
      'pager'    => $pager,
      'items'    => $index,
      'size'     => $index.elems,
      'tag'      => $tag,
    },
  };

  my $content = self!parse-page(%pagedef);
  my $outfile = $!config<output> ~ self!index-path($page, $tag);
  self!output-file($outfile, $content);

  if $to < $index.end {
    self!build-index($page+1, $index, $tag, $perpage);
  }
}

## Build story pages
method !build-story ($index, $page) {
  my %story = self!get-page($page);
  %story<type> = 'story';
  %story<data><items> = $index;
  %story<data><size> = $index.elems;
  
  my $content = self!parse-page(%story);
  my $outfile = $!config<output> ~ self!story-path($page);
  self!output-file($outfile, $content);
  self!process-indexes(%story);
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
  if (defined $!flower) {
    print " replanting Flower, ";
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
  say " - Generated file: '$file'.";
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
method !index-path ($page=1, $tag?) {
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
method !index-cache ($tag? is copy) {
  if ! defined $tag { $tag = 'index'; }
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

