package Koha::Plugin::HKS3SubordinateItems::SubordinateItemsHooks::SubordinateItemsController;

use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use C4::Debug;
use C4::Output qw(:html :ajax pagination_bar);
use C4::Biblio;
use C4::XSLT;

use C4::Biblio;
use C4::XSLT;

use C4::External::Amazon;

use Koha::Biblios;
use Koha::Items;
use Mojo::JSON qw(decode_json encode_json);

my $translate = {
    'de-DE' => 
        {dt      => 'https://cdn.datatables.net/plug-ins/1.10.21/i18n/German.json',
         columns => ['Daten', 'Band', 'Jahr', 'Cover'],
         label   => 'Bände',
        },
    'si-SI' => 
        {dt      => 'https://cdn.datatables.net/plug-ins/1.10.21/i18n/Slovenian.json',
        }
};

sub get {
    my $c = shift->openapi->valid_input or return;
    my $biblionumber = $c->validation->param('biblionumber');
    my $type  = $c->validation->param('type');
    my $lang_query  = $c->validation->param('lang');
    my $record       = GetMarcBiblio({ biblionumber => $biblionumber });
    my $dbh = C4::Context->dbh;
    
    my $controlfield = $record->field('001');
    
    my $internalid = $controlfield->data;

    my $sql= <<'SQL';
select * from ( SELECT bm.biblionumber,
    ExtractValue(metadata,'//datafield[@tag="773"]/subfield[@code="w"]') AS ITEM,
    ExtractValue(metadata,'//datafield[@tag="490"]/subfield[@code="v"]') AS volume,
    ExtractValue(metadata,'//datafield[@tag="264"][@ind2=" "]/subfield[@code="c"]') AS pub_date,
    isbn
  FROM biblio_metadata bm 
        join biblioitems bi on bi.biblionumber = bm.biblionumber) rel
    where item like ?
    order by volume desc, pub_date desc
SQL
    # implement ordering
    my $queryitem = $dbh->prepare($sql);
    $queryitem->execute($controlfield->data .'%');
    my $items = $queryitem->fetchall_arrayref({});
    
    return 0 unless scalar(@$items) > 0;
    
    my $xsl;
    my $htdocs;
    if ($type eq 'intranet') {
        $xsl = 'MARC21slim2intranetResults.xsl';
        $htdocs = C4::Context->config('intrahtdocs');
    } else {
        $xsl = 'MARC21slim2OPACResults.xsl';
        $htdocs = C4::Context->config('opachtdocs');
    }

    my ($theme, $lang) = C4::Templates::themelanguage($htdocs, $xsl, $type);
    $lang = $lang_query if $lang_query;
    
    $xsl = "$htdocs/$theme/$lang/xslt/$xsl";
    
    my $content = '';
    my $isbns = [];
    my $i = 0;
    my $data = [];
    foreach my $item (@$items) {
        $i++;
        my $xml = GetXmlBiblio($item->{biblionumber});
        my $biblioitem =  Koha::Biblioitems
                ->find( { 'biblionumber' => $item->{biblionumber} } );
        my $isbn = C4::Koha::GetNormalizedISBN($biblioitem->isbn);
        $isbn =~ s/\D//g;
        my $cr = C4::XSLT::engine->transform($xml, $xsl);
        push(@$data, [$cr, $item->{volume}, $item->{pub_date}, 
                      image_link($isbn)]);
    }

    return $c->render( status => 200, openapi => 
        { count => $i, ibsns => $isbns, data => $data,
          datatable_lang => $translate->{$lang}->{dt}, lang => $lang, 
          title => $translate->{$lang}->{columns}, 
          label => $translate->{$lang}->{label}, 
        } );
}


sub bytitle {
    my $c = shift->openapi->valid_input or return;
    my $title = $c->validation->param('title');
    my $dbh = C4::Context->dbh;

    my $sql= <<'SQL';
select 
    ExtractValue(metadata,'//controlfield[@tag="001"]') AS control,         
    b.title, 
    b.biblionumber 
from biblio b join biblioitems bi              
  on b.biblionumber = bi.biblionumber      
join biblio_metadata bm       
  on bi.biblionumber = bm.biblionumber 
where b.title like ?
  and substring(ExtractValue(metadata,'//leader'), 8, 1) = 's';
SQL
    # implement ordering
    my $queryitem = $dbh->prepare($sql);
    $queryitem->execute($title .'%');
    my $items = $queryitem->fetchall_arrayref({});

    return 0 unless scalar(@$items) > 0;

    my $type = 'intranet';
    my $xsl = 'MARC21slim2intranetResults.xsl';
    my $htdocs = C4::Context->config('intrahtdocs');

    my ($theme, $lang) = C4::Templates::themelanguage($htdocs, $xsl, $type);
    $lang = 'en';

    $xsl = "$htdocs/$theme/$lang/xslt/$xsl";

    my $content = '';
    my $i = 0;
    my $data = [];
    foreach my $item (@$items) {
        $i++;
        my $xml = GetXmlBiblio($item->{biblionumber});
        my $cr = C4::XSLT::engine->transform($xml, $xsl);
        my $select = sprintf('<input type="radio" id="%d" name="parent_radio" value="%d" title="%s">', 
                            $item->{control}, $item->{control}, $item->{title});
        push(@$data, [$select, $item->{title}, $cr, $item->{biblionumber}, $item->{control}]);
    }

    return $c->render( status => 200, openapi => 
        { 
            count => $i,
            data => $data,
        } );
}


sub image_link {
    my $isbn = shift;
    my $title = shift;
    my $link = '<div></div>';

    if ( C4::Context->preference('OPACAmazonCoverImages') ) {
        my $amazon_link = '<a href="http://www.amazon%s/gp/reader/%s%s';
        if (C4::Context->preference('OPACURLOpenInNewWindow')) {
            $amazon_link .= '#reader-link" target="_blank" rel="noreferrer">'
        } else {
            $amazon_link .= '">'
        }

        $amazon_link .= '<img border="0" src="https://images-na.ssl-images-amazon.com/images/P/%d.01.MZZZZZZZ.jpg" alt="Cover image" /></a>';

        $link = sprintf($amazon_link,
                        get_amazon_tld(),
                        $isbn,
                        C4::Context->preference('AmazonAssocTag'),
                        $isbn,
                        );
    }

    if ( C4::Context->preference('GoogleJackets') ) {
        $link .= sprintf('<div title="%s" class="%s" id="gbs-thumbnail-preview"></div>', $isbn,$isbn);
        $link .= sprintf('<div class="google-books-preview">
<img border="0" src="https://books.google.com/books/content?vid=ISBN%s&printsec=frontcover&img=1&zoom=1"/></div>', $isbn);
    }

    return $link;
}      

1;

__END__
    select * from ( SELECT biblionumber,
    ExtractValue(metadata,'//datafield[@tag="773"]/subfield[@code="w"]') AS ITEM FROM biblio_metadata ) rel
    where item like ?

