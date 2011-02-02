## White Noise: A static site generator.
## Designed for huri.net, but usable elsewhere.

use v6;

class WhiteNoise;

use JSON::Tiny;
use Exemel;
use Flower;
use File::Mkdir;
use DateTime::Math; ## Included with DateTime::Utils.

has $!flower;
has $.config;

## Caches for optimization purposes.
has %!cache-cache;
has %!page-cache;
has %!story-cache;
has %!folder-cache;
has %!file-cache;
has %!date-cache;

## Page Plugins.
has %!plugins;

## Pages to build
has %!pages;
## Stories to build
has %!stories;
## Indexes to build
has %!indexes;

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

## Add a page to the build queue.
method add-page ($file) {
  if $file.IO !~~ :f { say "skipping missing page '$file'..."; return; }
  %!pages{$file} = True;
}

## Add a story to the build queue.
method add-story ($cache, $file) {
  if $file.IO !~~ :f { say "skipping missing story '$file'..."; return; }
  %!stories{$file} = $cache;
}

## Add an index to the build queue.
method add-index ($cache, $tag?) {
  my $key = 'index';
  if ($tag) { $key = $tag; }
  %!indexes{$key} = $cache;
}

## The main process that starts the build
method generate () {
  for %!pages.keys -> $page {
    self!build-page($page);
  }
  for %!stories.kv -> $file, $cache {
    self!build-story($cache, $file);
  }
  for %!indexes.kv -> $tag, $cache {
    if ($tag eq 'index') {
      self!build-index(1, $cache);
    }
    else {
      self!build-index(1, $cache, $tag);
    }
  }
  ## Now we save caches to disk.
  self!save-caches();
}

## Re-generate from an index. By default, the site index.
method regenerate ($index?, $story?) {
  my $cache;
  if ($index) {
    $cache = $index;
  }
  else {
    $cache = self!index-cache();
  }
  my $listing = self!load-cache($cache);
  if (!$story) {
    $listing.=reverse; ## Process in reverse order.
  }
  for @($listing) -> $item {
    if $item<type> eq 'article' { 
      self.add-page($item<file>);
    }
    elsif $item<type> eq 'story' {
      my $storycache = self!story-cache($item<file>);
      self.regenerate($storycache, True);
    }
  }
}

## Build a page. This is the most basic of the building methods.
method !build-page ($file) {
  say "Processing '$file': ";
  my %page = self!get-page($file);
  my $pagecontent = self!parse-page(%page);
  my $outfile = $!config<output> ~ self!page-path(%page);
  self!output-file($outfile, $pagecontent);
  if (%page<data>.exists('parent')) {
    self!process-story(%page);
  }
  elsif (!%page<data><noindex>) {
    self!process-indexes(%page);
  }
}

method !load-cache ($file, $needcache?) {
  if %!cache-cache.exists($file) {
    return %!cache-cache{$file};
  }
  if $file.IO ~~ :f {
    say " *** Loading cache '$file'.";
    my $text = slurp($file);
    my $json = from-json($text);
    %!cache-cache{$file} = $json;
    return $json;
  }
  else {
    if $needcache {
      die "cache file '$file' is missing.";
    }
    say " *** Creating cache '$file'.";
    return []; # default cache, an empty array.
  }
}

## This used to write to disk, now it just caches in memory.
method !save-cache($file, $data) {
  %!cache-cache{$file} = $data;
}

## Now we save all file caches at once.
method !save-caches () {
  for %!cache-cache.kv -> $file, $data {
    my $text = to-json($data);
    self!output-file($file, $text);
  }
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

## Handles different datetime formats.
method !get-datetime ($updated) {
  if %!date-cache.exists($updated) {
    return %!date-cache{$updated};
  }
  my $dt;
#  say " >> Datestamp: $updated";
  if ($updated ~~ Int || $updated ~~ /^\d+$/) { ## If we find an epoch value.
    $dt = DateTime.new($updated.Int);
  }
  else {
    $dt = DateTime.new(~$updated);
  }
  %!date-cache{$updated} = $dt;
  return $dt;
}

## Add pages to indexes or stories.
method !add-to-list (%page, $tag?, $story?) {
  my $name = 'main';
  if ($tag) { $name = $tag; }
  #say "Generating $name index:";
  my $cachefile; 
  if ($story) {
    $cachefile = self!story-cache($story);
  }
  else {
    $cachefile = self!index-cache($tag);
  }
  my $cache = self!load-cache($cachefile);
  my $pagelink = self!page-path(%page);
  #say " - Adding $pagelink to index...";
  my $pagedata = %page<data>;

  ## We have a few methods to find out when a page was updated.
  my $updated;
  if $pagedata.exists('updated') {
    $updated = self!get-datetime($pagedata<updated>);
  }
  elsif $pagedata.exists('changelog') {
    my $newest = $pagedata<changelog>[0]<date>;
    $updated = self!get-datetime($newest);
  }
  elsif $pagedata.exists('items') {
    my $pageitems = $pagedata<items>;
    my $lastitem = $pageitems[$pageitems.end];
    my $lastdate = $lastitem<updated>;
    $updated = self!get-datetime($lastdate);
  }
  ## If none of the above worked, make it now.
  else {
    $updated = DateTime.now;
    %!date-cache{$updated.Str} = $updated;
  }

  my $snippet = %page<xml>.elements(:id<snippet>);
  if ($snippet.elems > 0) {
    $snippet = $snippet[0];
  }
  else {
    $snippet = %page<xml>.elements()[0];
  }

  my $type = 'article';
  if (%page.exists('type')) {
    $type = %page<type>;
  }

  my $pagedef = {
    'type'      => $type,
    'file'      => %page<file>,
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

  ## And add a chapter number, if it exists.
  if $pagedata.exists('chapter') {
    $pagedef<chapter> = $pagedata<chapter>;
  }

  ## And now, for some magic tricks.
  ## If your templates need extra fields from the
  ## page data, you can include a field called
  ## 'index' which is an array of data fields to include.
  if $pagedata.exists('index') {
    for @($pagedata<index>) -> $section {
      if ($section == 'link' | 'title' | 'updated' | 'snippet' 
        | 'tags' | 'content' ) 
      {
        ## Skip any sections that we shouldn't be overriding.
        next;
      }
      if $pagedata.exists($section) {
        $pagedef{$section} = $pagedata{$section};
      }
    }
  }

  ## Put things in there place.
  ## We now default to 'smartlist' mode.
  ## If you want the old 'dumb' behavior,
  ## add "smartlist" : 0 in your config.
  my $added = False;
  my $smartlist = True;
  if ($.config.exists('smartlist')) {
    $smartlist = $.config<smartlist>;
  }

  if $cache.elems > 0 { ## If there are items, lets do some magic.
    loop (my $i=0; $i < $cache.elems; $i++) {
      ## Handle the old link.
      if $cache[$i]<link> eq $pagelink {
        #say " * Updating '$pagelink' in cache.";
        if ($story) { ## Story pages should be put back in the same place.
          $cache.splice($i, 1, $pagedef);
          $added = True;
          last;
        }
        else { ## Non-story pages should have their old entry removed.
          $cache.splice($i, 1);
        }
      }
      elsif $smartlist { ## Date and/or chapter comparisons.
        #say " >> We're using SmartList mode.";
        if (
          $story 
          && $cache[$i].exists('chapter') 
          && $pagedef.exists('chapter')
          && $cache[$i]<chapter> > $pagedef<chapter>
        ) { ## Unlikely, but possible when importing.
          #say " >> A story entry was found in wrong order.";
          $cache.splice($i, 0, $pagedef);
          $added = True;
          last;
        }
        elsif (
          !$story
          && !$added
          && $cache[$i].exists('updated')
        ) {
          my $cdate = self!get-datetime($cache[$i]<updated>);
          if ($cdate < $updated) {
            #say " >> Found an entry older {$cdate.posix} than this one {$updated.posix}.";
            $cache.splice($i, 0, $pagedef);
            $added = True;
          }
        }
      }
    }
  }
  ## If all else fails, fallback to default behavior.
  if !$added {
    if ($story) {
      $cache.push: $pagedef;
    }
    else {
      $cache.unshift: $pagedef;
    }
  }

  self!save-cache($cachefile, $cache);

  ## Now, let's add the story/index to the build queue.
  if ($story) {
    self.add-story($cache, $story);
  }
  else {
    self.add-index($cache, $tag);
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
    #print " - Calling '$module' plugin... ";
    my $plugin = self!load-plugin($module);
    $plugin.parse(%page);
    #say "done.";
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
    #print " replanting Flower, ";
    $!flower.=another(:file($template));
  }
  else {
    $!flower = Flower.new(:file($template));
    if $!config<templates>.exists('plugins') {
      my @modifiers = $!config<templates><plugins>;
#      for @modifiers -> $modifier {
#        print "loading $modifier, ";
#      }
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

## Extract the root from a filename.
method !get-filename ($file) {
  if %!file-cache.exists($file) {
    return %!file-cache{$file};
  }
  my @filepath = $file.subst(/\/$/, '').split('/');
  my $filename = @filepath[@filepath.end];
  $filename ~~ s:g/\.xml$//;
  %!file-cache{$file} = $filename;
  return $filename;
}

## Paths for pages (articles and story chapters.)
method !page-path (%page) {
  my $file = %page<file>;
  my $opts = %page<data>;
  if (%!page-cache.exists($file)) {
    return %!page-cache{$file};
  }
  my $filename = self!get-filename($file);

  my $dir;
  if ($opts.exists('parent')) { 
    $dir = self!story-folder($opts<parent>);
  }
  else {
    $dir = '/articles';
    if !$opts<toplevel> {
      my $date = False;
      if ($opts.exists('updated')) {
        $date = $opts<updated>;
      }
      elsif ($opts.exists('changelog')) { # Please put changelog in newest first.
        my $cl = $opts<changelog>;
        my $last = $cl[$cl.end];
        $date = $last<date>;
      }
      if ($date) {
        my $dt = self!get-datetime($date);
        my $year = $dt.year;
        my $month = '%02d'.sprintf($dt.month);
        $dir ~= '/' ~ $year ~ '/' ~ $month;
      }
    }
  }
  self!make-output-path($dir);
  my $outpath = $dir ~ '/' ~ $filename ~ '.html';
  %!page-cache{$file} = $outpath;
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

## Story paths are used both for the story index
## and the story pages. So, here's the common version.
method !story-folder ($file) {
  if %!folder-cache.exists($file) {
    return %!folder-cache{$file};
  }
  my $filename = self!get-filename($file);
  my $folder = '/stories/' ~ $filename;
  %!folder-cache{$file} = $folder;
  return $folder;
}

## The path for the story table of contents.
method !story-path ($file) {
  if (%!page-cache.exists($file)) {
    return %!page-cache{$file};
  }
  my $folder = self!story-folder($file);
  self!make-output-path($folder);
  my $outpath = $folder ~ '/index.html';
  %!page-cache{$file} = $outpath;
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
  if (%!story-cache.exists($file)) {
    return %!story-cache{$file};
  }
  my $filename = self!get-filename($file);

  my $dir = './cache/stories';
  if ($!config.exists('stories') && $!config<stories>.exists('folder')) {
    $dir = $!config<stories><folder>;
  }
  mkdir $dir, :p;
  my $cachedir = $dir ~ '/' ~ "$filename.json";
  %!story-cache{$file} = $cachedir;
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

