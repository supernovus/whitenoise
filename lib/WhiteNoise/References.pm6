use v6;
use WhiteNoise::Plugin;

class WhiteNoise::References does WhiteNoise::Plugin;

use Exemel;

## Transform special 'ref:' attributes in <a/> tags
method parse (%page is rw) {
  if (!%page.exists('xml')) { return; } ## Skip non-pages.
  my $xml = %page<xml>;
  my %args = {
    :TAG<a>,
    :RECURSE(10),
    'ref:site' => True,
  };
  my @references = $xml.elements(|%args);
  for @references -> $ref is rw {
    my $site = $ref.attribs<ref:site>;
    ## A default URL in case someone screws up a reference name.
    my $refurl = "http://www.google.com/search?q=%s";
    if (
         $.engine.config.exists('refs') 
      && $.engine.config<refs>.exists($site) 
    ) {
      $refurl = $.engine.config<refs>{$site};
    }
    my $term;
    if ($ref.attribs.exists('ref:term')) {
      $term = $ref.attribs<ref:term>;
    }
    else {
      my $content = $ref.nodes[0]; ## should be a text node.
      if $content ~~ Exemel::Text {
        $term = ~$content;
      }
    }
    my $url = $refurl.sprintf($term);
    $ref.attribs<href> = $url;
    $ref.attribs.delete('ref:site');
    if $ref.attribs.exists('ref:term') {
      $ref.attribs.delete('ref:term');
    }
  }
}

