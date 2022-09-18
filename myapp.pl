#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use lib qw(lib);
#$r->get('/register')->to(
#    controller => 'RegistrationController', action => 'register'
#);
use MIME::Base64;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Text::CSV;
use Crypt::PBKDF2;
use List::Util qw(max);

use DBI;

use Data::Printer;


plugin 'TagHelpers';

our $dbh;
our $ua  = Mojo::UserAgent->new;
# XXX DEVELOPEMENT
$ua = $ua->insecure(1);

app->hook(before_server_start => sub {
    my ($server, $app) = @_;
    $app->dbcreate;
  });

##### Database
our $db = 'mtg.db';
our $dbhost = '';
our $dbport = '';
our $dbuser = '';
our $dbpassword= '';
our $driver   = "SQLite";

helper dbh => sub {
  state $dbh = $dbh or undef;
  if (not defined $dbh) {
    my $data_source;
    if ( "MySQL" eq $driver ) {
      $data_source = "dbi:$driver:dbname=$db;host=$dbhost;port=$dbport";
    }
    if ( "SQLite" eq $driver ) {
      $data_source = "dbi:$driver:dbname=$db";
    }
    $dbh = DBI->connect($data_source, $dbuser, $dbpassword,
      {ChopBlanks=>1, AutoCommit=>1,RaiseError=>0,PrintError=>1})
      or die $DBI::errstr;
    print "Opened database successfully\n";
  }

  return $dbh;
};

helper dbcreate => sub {
  my $c = shift;
  my $rv = undef;

  my $schema = { 'create_table' => [ 'collection', 'users']};
  foreach my $key (sort keys %{$schema}) {
    foreach my $table (values @{$schema->{$key}}) {
      my $path = Mojo::File->new($key.'_' . $table . '.sql');
      my $stmt = $path->slurp;
      foreach (split(/;/, $stmt)) {
        $rv = $c->dbh->do($_.";");
        if($rv lt 0) {
          #Var DBI::errstr ist in diesem Kontext unbekannt
          print "DBI Error (rv lt 0)\n";
        } else {
          say $key . ' ' . $table . " created successfully";
        }
      }
    }
  }
};

helper get_data => sub {
  my $c = shift;
  my $stmt = shift;
  my $orderByKey = shift || 'ID';

  my $sth = $c->dbh->prepare("$stmt");

  $sth->execute or die $DBI::errstr;
  if (defined $sth) {
    my $rows =  $sth->fetchall_hashref($orderByKey);
    $sth->finish();
    return $rows;
  }
  return undef;
};

helper get_datalist => sub {
  my $c = shift;
  my $stmt = shift;
  my $orderByKey =  shift || [ 'ID', 'Name' ];

  my $data = $c->get_data($stmt, ${$orderByKey}[1]);
  my $res = {};
  foreach my $cardID (keys %{$data}) {
    $res->{$data->{$cardID}->{${$orderByKey}[0]}}->{$cardID} = $data->{$cardID};
  }
  return $res;
};

helper get_id => sub {
  my $c = shift;
  my $name = shift;
  my $table = shift;

  my $sth = $c->dbh->prepare("SELECT ID FROM $table WHERE Name == '$name';");
  $sth->execute or die $DBI::errstr;
  my $nameid = $sth->fetch();
  return @{$nameid}[0] if (defined $nameid);
  return undef
};

helper insert_collection => sub {
  my $c = shift;
  my $name = shift;
  my $edition = shift;
  my $price = shift;
  my $cardnumber = shift;
  
  my $sth = $c->dbh->prepare("INSERT INTO mtg (Name, Edition, Preis, CardNumber) VALUES( '$name', '$edition', '$price', '$cardnumber');");
  my $ret = $sth->execute or say $DBI::errstr;
  return undef if (not defined $ret or $ret eq "E0E");

  return $c->get_id($name, "mtg");
};

helper insert_users => sub {
  my $c = shift;
  my $name = shift;
  my $password = shift;
  
  my $sth = $c->dbh->prepare("INSERT INTO users (Name, Password) VALUES( '$name', '$password');");
  my $ret = $sth->execute or say $DBI::errstr;
  return undef if (not defined $ret or $ret eq "E0E");

  my $id = $c->get_id($name, "users");
  $ret = $c->create_user_collection($id);
  return undef if (not defined $ret or $ret eq "E0E");
  $ret = $c->create_user_deck($id);
  return undef if (not defined $ret or $ret eq "E0E");

  return $id;
};












helper create_deck => sub {
  my $c = shift;
  my $name = shift;
  my $userID = shift;
  
  my $sth = $c->dbh->prepare("INSERT INTO deck (UserID, Name) VALUES( '$userID' ,'$name');");
  my $ret = $sth->execute or say $DBI::errstr;
  return undef if (not defined $ret or $ret eq "E0E");

  my $id = $c->get_id($name, "deck");
  return $id;
};

helper modify_deck => sub {
  my $c = shift;
  my $jsonData = shift;

  my $userID = $c->session('userID') || undef;
  return undef unless (defined $userID);
  my $deckID = (keys %{$jsonData})[0];
  my $res = $c->get_data("SELECT ID, cardID  FROM user_deck_$userID WHERE ID = '$deckID';", 'cardID');

  my $stmt = "";
  foreach my $cardID ( keys %{$jsonData->{$deckID}}) {
    my $amount = $jsonData->{$deckID}->{$cardID};

    if (defined $res and exists $res->{$cardID}) {
      $stmt = "UPDATE user_deck_$userID SET Count = '$amount' WHERE ID = '$deckID' AND cardID = '$cardID';";
    } else {
      $stmt = "INSERT INTO user_deck_$userID (ID, cardID, Count) VALUES('$deckID', '$cardID', '$amount');";
    }
    my $sth = $c->dbh->prepare($stmt);
    return -1 unless defined $sth;
    my $ret = $sth->execute or say $DBI::errstr;
    $sth->finish();
    delete $res->{$cardID};
  }

  foreach my $cardID ( keys %{$res}) {
    my $stmt = "DELETE FROM user_deck_$userID WHERE ID = '$deckID' and cardID = '$cardID';";
    my $sth = $c->dbh->prepare($stmt);
    return -1 unless defined $sth;
    my $ret = $sth->execute or say $DBI::errstr;
    $sth->finish();
  }
  #return undef if (not defined $ret or $ret eq "E0E");
};

helper create_user_collection => sub {
  my $c = shift;
  my $id = shift;
  my $stmt = "CREATE TABLE IF NOT EXISTS user_collection_$id (
    ID INTEGER NOT NULL UNIQUE,
    Count INTEGER NOT NULL,
    FOREIGN KEY (ID)
    REFERENCES mtg (ID) 
    ON DELETE CASCADE ON UPDATE NO ACTION,
    UNIQUE (ID) ON CONFLICT IGNORE
    );";
  my $sth = $c->dbh->prepare($stmt);
  my $ret = $sth->execute or say $DBI::errstr;
  return $ret;
};

helper create_user_deck => sub {
  my $c = shift;
  my $id = shift;
  my $stmt = "CREATE TABLE IF NOT EXISTS user_deck_$id (
      ID INTEGER NOT NULL,
      cardID INTEGER NOT NULL,
      Count INTEGER NOT NULL,
      PRIMARY KEY (cardID, ID),
      FOREIGN KEY (cardID)
      REFERENCES mtg (ID) 
      ON DELETE CASCADE ON UPDATE NO ACTION,
      FOREIGN KEY (ID)
      REFERENCES deck (ID) 
      ON DELETE CASCADE ON UPDATE NO ACTION
    );";
  my $sth = $c->dbh->prepare($stmt);
  my $ret = $sth->execute or say $DBI::errstr;
  return $ret;
};

helper insert_user_collection => sub {
  my $c = shift;
  my $cardid = shift;
  my $count = shift;
  my $id = $c->get_id($c->session('user'), 'users');
  my $stmt = "INSERT INTO user_collection_$id (ID , Count) VALUES ($cardid, $count);";
  my $sth = $c->dbh->prepare($stmt);
  my $ret = $sth->execute or say $DBI::errstr;
  return $ret;
};

helper update_scraped => sub {
  my $c = shift;
  my $id = shift;
  my $oracle = shift;
  my $mana_costs = shift;
  my $image = shift;
  my $type = shift;
  my $rawdata = shift;
  my $h = "UPDATE mtg SET Oracle='$oracle', ManaCost='$mana_costs', Type='$type', Image='$image', Rawdata='$rawdata' WHERE ID=='$id';";
  my $sth = $c->dbh->prepare($h);
  my $ret = $sth->execute or say $DBI::errstr;
  return undef if (not defined $ret or $ret eq "E0E");

  return $id;
};

helper delete_from => sub {
  my $c = shift;
  my $table = shift;
  my $where = shift;
  my $stmt = "DELETE FROM $table WHERE $where;";
  my $sth = $c->dbh->prepare($stmt);
  my $ret = $sth->execute or say $DBI::errstr;
  return $ret;
};

get '/' => sub ($c) {
  $c->render(template => 'index');
};

our $scrapeTimerID = Mojo::IOLoop->recurring(75 => sub ($loop) {
    my $scrapeSubprocess = $loop->subprocess;
    $scrapeSubprocess->on(
      progress => sub($subproc, @data) {
        my $res = $data[0];
        app->update_scraped(
          $res->{id},
          $res->{oracle},
          $res->{mana_cost},
          $res->{image},
          $res->{type},
          $res->{rawdata}
        );
      });
    $scrapeSubprocess->on(cleanup => sub ($subprocess) { say "Process $$ is about to exit" });
    # Fine grained response handling (dies on connection errors)
    $scrapeSubprocess = $scrapeSubprocess->run( sub ($subprocess) {
        # XXX autoconfigure  LIMIT from network speed
        my $rows = app->get_data('SELECT ID, Name FROM mtg WHERE Rawdata IS NULL LIMIT 15');
        foreach my $key (keys %{$rows}) {
          my $id = $rows->{$key}->{'ID'};
          my $name = $rows->{$key}->{'Name'};
          $name =~ s/ \(.+\)$//g;
          chomp($name);
          $name =~ s/ /+/g;
          print "$name\n";
          app->process_scrape($name, $id, $subprocess);
          #$c->process_scrape($name, $id, undef);
        }
      });
  });

helper process_scrape => sub {
  my $c = shift;
  my $name = shift;
  my $id = shift;
  my $subproc = shift || undef;
  my $ua  = Mojo::UserAgent->new();
  $ua = $ua->ioloop($subproc->ioloop) if (defined $subproc) ;
  # XXX DEVELOPEMENT
  $ua = $ua->insecure(1);
  $ua = $ua->connect_timeout(30)->request_timeout(45);

  my $xpath = 'div[class=toolbox-column] > ul[class=toolbox-links] > li > a > b';
  say "search on scryfall";
  my $res = $ua->max_redirects(2)->get("https://scryfall.com/search?q=$name")->result;
  print "fetched anchore child \n";
  my $toolboxLinks = $res->dom->find($xpath);

  # possible a grid
  unless (defined $toolboxLinks and $toolboxLinks->size) {
    print "find griditems\n";
    my $griditem = $res->dom->find('a[class=card-grid-item-card] > span[class=card-grid-item-invisible-label]');
    foreach ($griditem->each) {
      $name =~ s/\+/ /g;
      if ($_->text eq "$name") {
        print "refetch anchore child after cardgrid\n";
        $toolboxLinks = $ua->max_redirects(2)->get($_->parent->attr->{href})->result->dom->find($xpath);
        last;
      }
    }
  }

  my $JSONLink = $toolboxLinks->first(qr/JSON/)->parent->attr->{href};
  print "fetch json\n";
  my $jsonres = $ua->get($JSONLink)->result;
  my $json  = $jsonres->json;

  my $oracle = "";
  my $type = "";
  my $mana = undef;
  my $imageURL = undef;
  # test on Transform card
  if ( defined $json->{card_faces} and values @{$json->{card_faces}}) {
    say "is Transform";
    foreach (values @{$json->{card_faces}}) {
      unless (defined $oracle) {
        $oracle = $_->{oracle_text}
      } else {
        if (defined $_->{oracle_text}) {
          $oracle .= "\n\n $_->{oracle_text}"
        }
      }
      unless (defined $type) {
        $type = $_->{type_line}
      } else {
        if (defined $_->{type_line}) {
          $type .= "\n\n $_->{type_line}"
        }
      }

      if (not defined $imageURL and defined $_->{image_uris}->{small}) {
        $imageURL = $_->{image_uris}->{small};
      } else {
        if (defined $json->{image_uris}->{small}){
          $imageURL = $json->{image_uris}->{small};
        }
      }
      unless (defined $mana) {
        $mana = $_->{mana_cost}
      } else {
        if (defined $_->{mana_cost}) {
          $mana .= " // $_->{mana_cost}"
        }
      }

    }
  } else {
    $oracle = $json->{oracle_text};
    $type = $json->{type_line};
    $mana = $json->{mana_cost};
    $imageURL = $json->{image_uris}->{small};
  }

  $type =~ s/Ã¢ÂÂ/-/g;
  $oracle =~ s/'/''/g;
  $oracle =~ s/Ã¢ÂÂ/-/g;
  $oracle =~ s/Ã¢ÂÂ¢/"/g;
  print "fetching image \n";
  my $image = encode_base64($ua->max_redirects(2)->get($imageURL)->result->body or undef);
  
  if (defined $subproc) {
  print "update collection for $name\n";
  $subproc->progress({
      id => $id,
      oracle => $oracle,
      mana_cost => $mana,
      image => $image,
      type => $type,
      rawdata => encode_base64($jsonres->body)
    });
  } else {
    $c->update_scraped(
      $id,
      $oracle,
      $mana,
      $image,
      $type,
      encode_base64($jsonres->body)
    );
  }
};

get '/register' => sub ($c) {
  $c->render(
    template => 'register',
    error    => $c->flash('error'),
    message  => $c->flash('message')
  );
};

post '/register' => sub($c) {
  my $username = $c->param('username');
  my $password = $c->param('password');
  my $confirm_password = $c->param('confirm_password');

  if (! $username || ! $password || ! $confirm_password ) {
    $c->flash( error => 'Username, Password are the mandatory fields.');
    $c->redirect_to('register');
  }

  if ($password ne $confirm_password) {
    $c->flash( error => 'Password and Confirm Password must be same.');
    $c->redirect_to('register');
  }

  my $users = $c->get_data("SELECT ID FROM users WHERE Name='$username';");

  if ( defined $users and ! keys %{$users}  ) {
    eval {
      $c->insert_users($username, generate_password($password) )
    };
    if ($@) {
      $c->flash( error => 'Error in db query. Please check mysql logs.');
      $c->redirect_to('register');
    }
    else {
      $c->flash( message => 'User added to the database successfully.');
      $c->redirect_to('login');
    }
  }
  else {
    $c->flash( error => 'Username already exists.');
    $c->redirect_to('register');
  }
};

sub generate_password {
  my $password = shift;

  my $pbkdf2 = Crypt::PBKDF2->new(
    hash_class => 'HMACSHA1', 
    iterations => 1000,       
    output_len => 20,         
    salt_len   => 4,         
  );

  return $pbkdf2->generate($password);
};

get '/login' =>  sub($c) {
  $c->render(
    template => 'login',
    error    => $c->flash('error'),
    message  => $c->flash('message')
  );
};

post '/login' =>  sub($c) {
  my $user = $c->param('username');
  my $pass = $c->param('password');

  unless ($c->login_check($user, $pass)) {
    $c->flash( error => 'Username or Password failed.');
    $c->redirect_to('login');
  } else {
    $c->session(user => $user);
    my $userID = $c->get_id("$user", 'users');
    $c->session(userID => $userID);
    my $decks = $c->get_data("SELECT ID, Name FROM deck WHERE UserID == '$userID';");
    $c->session(decks => $decks);
    $c->flash(message => 'Thanks for logging in.');
    $c->redirect_to(
      "user"
    );
  }
};

helper login_check => sub ($,$,$){
  my $c = shift;
  my $user = shift;
  my $pass = shift;
  my $id = $c->get_id($user, "users");
  if (defined $id) {
    my $res = $c->get_data("SELECT ID, Name, Password FROM Users WHERE Name = '$user'");
    my $pbkdf2 = Crypt::PBKDF2->new(
      hash_class => 'HMACSHA1', 
      iterations => 1000,       
      output_len => 20,         
      salt_len   => 4,         
    );
    return $pbkdf2->validate($res->{$id}->{Password},$pass) 
  } else { return 0;}

};

# Logout action
get '/logout' => sub ($c) {

  # Expire and in turn clear session automatically
  $c->session(expires => 1);

  # Redirect to main page with a 302 response
  $c->redirect_to('index');
};

group {
  under '/user' => sub($c) {
    # Redirect to main page with a 302 response if user is not logged in
    return 1 if $c->session('user');
    $c->redirect_to('/login');
    return undef;
  };
  get '/' => 'index';
  group {
    under 'deck';
    get 'create' => sub ($c) {
      $c->render(
        error    => $c->flash('error'),
        message  => $c->flash('message'),
        template => 'createdeck'
      );
    } => 'createdeck';

    post 'create' => sub($c) {
      #https://docs.mojolicious.org/Mojolicious/Guides/Rendering#Form-validation
      my $name = $c->param('deckname');
      my $id = $c->session('userID') || -1;
      $name =~ s/'/''/g;
      my $deckID = $c->create_deck("$name",$id);
      my $decks = $c->get_data("SELECT ID, Name FROM deck WHERE UserID == '$id';");
      $c->session('deckID' => $deckID);
      $c->session('decks' => $decks);
      $c->redirect_to('modifydeck');
    } => 'createdeck';

    get 'delete' => sub ($c) {
      my $id = $c->session('userID') || -1;
      my $decks = $c->get_data("SELECT ID, Name FROM deck WHERE UserID == '$id';");
      $c->session('decks' => $decks);
      my @list = (); 
      foreach (keys %{$decks}) {
        push(@list, [$decks->{$_}->{'Name'} => $_]);
      }
      $c->render(
        error    => $c->flash('error'),
        message  => $c->flash('message'),
        decks  => \@list,
        template => 'deletedeck'
      );
    } => 'deletedeck';

    post 'delete' => sub ($c) {
      my $deckID = $c->param('decknames');
      if (defined $c->session("decks")->{$deckID}) {
        my $rc = $c->delete_from('deck', "ID == '$deckID'");
        if ($rc) {
          my $name = $c->session('decks')->{$deckID}->{'Name'};
          $c->flash('message' => "successfull delete deck  $name");
        } else {
          my $name = $c->session('decks')->{$deckID}->{'Name'};
          $c->flash('error' => "deck $name could not delete!");
        }
      } else {
        $c->flash('error' => "access denied");
      }
      $c->redirect_to(
        template => 'delete'
      );
    } => 'deletedeck';

    get 'modify' => sub ($c){
      my $decks = $c->session('decks');
      my @list = (); 
      foreach (keys %{$decks}) {
        push(@list, [$decks->{$_}->{'Name'} => $_]);
      }

      $c->render(
        error    => $c->flash('error'),
        message  => $c->flash('message'),
        decks  => \@list,
        template => 'modifydeck'
      );
    } => 'modifydeck';

    get 'watch' => 'watchdeck';
  }
};


group {
  under 'collection';
  # Upload form in DATA section
  get 'upload' => 'form';

  # Multipart upload handler
  post 'upload' => sub ($c) {

      #https://docs.mojolicious.org/Mojolicious/Guides/Rendering#Form-validation
    # Check file size
    return $c->render(text => 'File is too big.', status => 200) if $c->req->is_limit_exceeded;

    # Process uploaded file
    return $c->redirect_to('form') unless my $collection = $c->param('collection');

    $c->import_collection($collection);
  };
};

helper import_collection => sub($c, $collection) {

  my $subprocImportCollection = Mojo::IOLoop::Subprocess->new;
  my $promise = $subprocImportCollection->run_p( sub($subproc) {
      my $csv = Text::CSV->new({ sep_char => ',' });
      my $sum = 0;
      my $matrix = {};
      my @lines = split('\n', $collection->slurp);
      foreach my $line (@lines) {
        chomp($line);
        if ($csv->parse($line)) {

          my @fields = $csv->fields();
          push(@{$matrix->{$sum}}, $csv->fields());
          for (my $idx = 0; $idx < length($matrix->{$sum}); $idx++) {
            if ($matrix->{$sum}[$idx]) {
              $matrix->{$sum}[$idx] =~ s/'/''/;
              $matrix->{$sum}[$idx] =~ s/Ã¢ÂÂ/-/g;
              $matrix->{$sum}[$idx] =~ s/Ã¢ÂÂ¢/"/g;
            }
          }
        } else {
          warn "Line could not be parsed: $line\n";
          $subproc->progress({ text => "Line could not be parsed: $line"})
        }

        # XXX some names are double check edition to, fuc sql hack
        my $id = $c->get_id($matrix->{$sum}[2] . "' AND Edition == '$matrix->{$sum}[3]",'mtg');

        
        unless ($id) {
          if ($sum gt 0) {
            $id = $c->insert_collection(
              $matrix->{$sum}[2],
              $matrix->{$sum}[3],
              $matrix->{$sum}[13],
              $matrix->{$sum}[4]
            );
            print "insert number: $sum, ID: $id\n";
            $subproc->progress({ text => "insert number: $sum, ID: $id"})
          }
        }

        ## XXX foils not count
        if ($c->session('user') and $id) {
          say "insert id $id";
          $c->insert_user_collection(
            $id,
            $matrix->{$sum}[0]
          );
        }
        $sum += 1;
      }
      return $matrix;
    })->then(sub ($matrix) {
      $c->render(json => $matrix);
    })->catch(sub ($err) {
      say $err;
      $c->render( text => 'Internal Server Error! see log' )
    })->wait;

};

get '/watch' =>  sub($c) {
  $c->render(template => 'watch');
};

websocket '/watch/ws' =>  sub($c) {
  my $stmt = "";
  if ($c->session('user')) {
    my $userid = $c->get_id($c->session('user'),"users");
    $stmt = "SELECT mtg.ID AS ID, Image, Name, Type, Oracle, ManaCost , Count FROM mtg INNER JOIN user_collection_$userid AS B ON mtg.ID = B.ID;";
  } else {
    $stmt = 'SELECT ID, Image, Name, Type, Oracle, ManaCost FROM mtg;';
  }
  my $rows = $c->get_data($stmt);
  my $rows_size = max(keys %{$rows})+20;

  # Opened
  $c->app->log->debug('WebSocket opened');
  $c->on(open => sub($c, $msg){
      $msg = {
        type => "database",
        data => undef,
        count => 0
      };
      $c->send(encode_json($msg));

    });
  # Increase inactivity timeout for connection a bit
  $c->inactivity_timeout(360);

  # TODO not all data was print
  # Incoming message
  $c->on(message => sub ($c, $rcvmsg) {
      my $rmsg = decode_json($rcvmsg);
      my $msg = {
        type => undef,
        data => undef,
        count => 0
      };

      if ("$rmsg->{type}" eq "database") {
        $msg = {
          type => "database",
          data => undef,
          count => $rmsg->{count}+20
        };
        my @part;
        foreach $_ ($rmsg->{count}+1 .. $rmsg->{count}+20) {
          push @part, { %{$rows->{$_}} } if (defined $rows->{$_});
          if ($_ > $rows_size) {
            $msg->{type} = "databaseend";
            last;
          };
        };

        $msg->{data} = [ @part ];
      };

      if ("$rmsg->{type}" eq "deck") {
        my $userID = $c->session('userID');
        my @orderByKeys = ('ID', 'cardID');
        my $decks = $c->get_datalist("SELECT ID, cardID, Count FROM user_deck_$userID;", \@orderByKeys);
        $msg->{type} = "deck";
        $msg->{data} = $decks;
      }

      if ("$rmsg->{type}" eq "modifydeck") {
          $c->modify_deck($rmsg->{data});
      }

      $c->send(encode_json($msg));
    });

  # Closed
  $c->on(finish => sub ($c, $code, $reason = undef) {
      $c->app->log->debug("WebSocket closed with status $code");
    });

};

app->start;
__DATA__

@@ list.html.ep
% layout 'default';
% title 'Imports';

@@ index.html.ep
% layout 'default';
% title 'Welcome to Magic the Gathering Card search';
<h1>Welcome to Magic the Gathering Card search</h1>
%= button_to "Watch and search"   => $self->url_for('watch')
%= button_to "Import Collection"  => $self->url_for('form')
%= button_to "Register" => 'register'
%= button_to "Login" => 'login'
%= button_to "Logout" => 'logout'

% if ($self->session('user')) {
%= button_to "Create a deck" => 'createdeck'
%= button_to "Delete a deck" => 'deletedeck'
%= button_to "show deck" => 'watchdeck'
%= button_to "Modify Deck" => 'modifydeck'
% }

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
<head>
<title><%= title %></title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
</head>
<body><%= content %></body>
</html>

@@ createdeck.html.ep
% layout 'default';
% title 'Create a Deck';
<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            Create Deck
        </div>
        <br /> <br />
        %= form_for create => (method => 'post') => begin
          %= input_tag 'deckname', type => 'username', id => 'deckname', placeholder => 'Enter deck name', size => "56"
            <br /> <br />
            %= submit_button 'Create Deck' => (class => 'btn btn-primary')
            <br />  <br />
        % end
      % if ($error) {
            <div class="error" style="color: red">
                <small> <%= $error %> </small>
            </div>
        %}

        % if ($message) {
            <div class="error" style="color: green">
                <small> <%= $message %> </small>
            </div>
        %}
    </div>

</div>

@@ deletedeck.html.ep
% layout 'default';
% title 'Delete a Deck';


<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            Delete Deck
        </div>
        <br /> <br />
        %= form_for deletedeck => (method => 'post') => begin
        %= select_field decknames => $decks
            <br /> <br />
            %= submit_button 'Delete Deck' => (class => 'btn btn-primary')
            <br />  <br />
        % end
      % if ($error) {
            <div class="error" style="color: red">
                <small> <%= $error %> </small>
            </div>
        %}

        % if ($message) {
            <div class="error" style="color: green">
                <small> <%= $message %> </small>
            </div>
        %}
    </div>

</div>

@@ modifydeck.html.ep
% layout 'default';
% title 'Modify a Deck';
<script>
var ws = new WebSocket('<%= url_for('watchws')->to_abs %>');
var msg = {"type":"database", "count":0, "data":null };
console.info(JSON.stringify(msg));

// Incoming messages
ws.onmessage = function (event) {
  json = JSON.parse(event.data);
  
  msg.type = json.type;
  msg.count = json.count;
  msg.data = null;
  if ("database" == json.type) {
    addRow(json.data, "cardTBody");
    ws.send(JSON.stringify(msg));
  }
  if ("databaseend" == json.type) {
    msg.type = "deck";
    msg.count = null;
    ws.send(JSON.stringify(msg));
  }
  if ("deck" == json.type) {
    for (const deckID in json.data ) {
      var decknames =document.getElementById("decknames");
      if (decknames.value != deckID) {continue;};
      for (const cardID in json.data[deckID]) {
        const  amount = json.data[deckID][cardID].Count;
        var inputCount =document.getElementById("inputCardAmount-"+cardID);
        inputCount.value = amount;
        var checkboxChoice =document.getElementById("checkboxChoice-"+cardID);
        checkboxChoice.checked = true;
        let event = new Event('change');
        checkboxChoice.dispatchEvent(event);
      }
    }
  }
};

// Outgoing messages
ws.onopen = function (event) {
  ws.send(JSON.stringify(msg));
};

function addRow(jsonContent, tableBody)
{
  if (!document.getElementsByTagName) return;
  if (!document.getElementById) return;
  tabBody=document.getElementById(tableBody);

  for (i = 0; i < jsonContent.length; i++) {
    row = document.createElement("tr");
    row.id = jsonContent[i].ID;

    cellImage = document.createElement("td");
    textImage = document.createElement("img");
    textImage.src='data:image/jpg;base64,'+jsonContent[i].Image;
    textImage.alt=jsonContent[i].Name;
    textImage.width="128";
    cellImage.appendChild(textImage);
    row.appendChild(cellImage);

    cellName = document.createElement("td");
    textName = document.createTextNode(jsonContent[i].Name);
    cellName.appendChild(textName);
    row.appendChild(cellName);

    cellType = document.createElement("td");
    textType = document.createTextNode(jsonContent[i].Type?.replace(/Ã¢ÂÂ/g,'-'));
    cellType.appendChild(textType);
    row.appendChild(cellType);

    cellManaCost = document.createElement("td");
    textManaCost = document.createTextNode(jsonContent[i].ManaCost);
    cellManaCost.appendChild(textManaCost);
    row.appendChild(cellManaCost);

    cellOracle = document.createElement("td");
    textOracle = document.createTextNode(jsonContent[i].Oracle?.replace(/Ã¢ÂÂ/g,'-').replace(/Ã¢ÂÂ¢/g,'"'));
    cellOracle.appendChild(textOracle);
    row.appendChild(cellOracle);

    cellChoice = document.createElement("td");
    formChoice = document.createElement("form");
    checkboxChoice = document.createElement('input');
    checkboxChoice.type = "checkbox";
    checkboxChoice.name = "checkboxChoice";
    checkboxChoice.id = "checkboxChoice-"+jsonContent[i].ID;
    checkboxChoice.addEventListener('change', (event) => {
        const myrow = event.currentTarget.parentNode.parentNode.parentNode;
        deckTBody=document.getElementById("deckTBody");
        if (event.currentTarget.checked) {
          document.getElementById("deckTBody").appendChild(myrow);
        } else {
          document.getElementById("cardTBody").appendChild(myrow);
        }
      })
    formChoice.appendChild(checkboxChoice);
    cellChoice.appendChild(formChoice);
    row.appendChild(cellChoice);

    cellCount = document.createElement("td");
    inputCount = document.createElement('input');
    inputCount.type = "number";
    inputCount.value = "1";
    inputCount.id = "inputCardAmount-"+jsonContent[i].ID;
    inputCount.size = 3;
    if (! jsonContent[i].Type?.includes("Basic Land")) {
      inputCount.max = 4;
    } else {
      inputCount.max = 99;
    }
    inputCount.min = 0;
    cellCount.appendChild(inputCount);
    row.appendChild(cellCount);

    tabBody.appendChild(row);
  }

};

const searchopt = {
  "Oracle" : 4,
  "ManaCost": 3,
  "Type": 2,
  "Name": 1
}

function searchCards(key) {
  // Declare variables
  var input, filter, table, tr, td, i, txtValue;
  input = document.getElementById("search"+key);
  filter = input.value.toUpperCase();
  table = document.getElementById("collectionTable");
  tr = table.getElementsByTagName("tr");

  // Loop through all table rows, and hide those who don't match the search query
  for (i = 0; i < tr.length; i++) {
    td = tr[i].getElementsByTagName("td")[searchopt[key]];
    if (td) {
      txtValue = td.textContent || td.innerText;
      if (txtValue.toUpperCase().indexOf(filter) > -1) {
        tr[i].style.display = "";
      } else {
        tr[i].style.display = "none";
      }
    }
  }
};

function modifydeck() {
  var json = {};

  const deckID = document.getElementById("decknames").value;
  const deck = document.getElementById("deckTBody")?.childNodes;
  
  json = {[deckID] : {}} 
  for (let idx = 1; idx < deck.length; idx++) {
    cardID = deck[idx].id;
    const amount = document.getElementById("inputCardAmount-"+cardID).value;
    json[deckID] = Object.assign(json[deckID], { [cardID] : amount })
  }
  msg = { type: "modifydeck", data : json };
  ws.send(JSON.stringify(msg));
}

</script>

<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            Modify Deck
        </div>
        %= form_for "#" => ( onsubmit=>"modifydeck()" ) => begin
          %= select_field decknames  => $decks, id => 'decknames'
          %= submit_button 'modify Deck' => (class => 'btn btn-primary')
        % end
        %= t 'br'
        %= t 'br'
        % if ($error) {
            <div class="error" style="color: red">
                <small> <%= $error %> </small>
            </div>
        %}

        % if ($message) {
            <div class="error" style="color: green">
                <small> <%= $message %> </small>
            </div>
        %}
    </div>
</div>
<div style="top: 0; width: 100%; padding: 5px; padding-top: 25px;">
<input type="text" id="searchType" onkeyup="searchDeck('Type')" placeholder="Search for type..">
<input type="text" id="searchOracle" onkeyup="searchDeck('Oracle')" placeholder="Search for oracle..">
</div>

<div style="padding-top: 5px;">
<table id="deckTable" style="width:100%">
<tbody>
<tr>
<th id="deckCardImage" scope="col">Image</th>
<th id="deckCardName" scope="col">Name</th>
<th id="deckCardType" scope="col">Type</th>
<th id="deckCardMana" scope="col">Mana Costs</th>
<th id="deckCardOracle" scope="col">Oracle</th>
<th id="deckCardChoice" scope="col">Choice</th>
<th id="deckCardCount" scope="col">Count</th>
</tr>
</tbody>
<tbody id="deckTBody">
</tbody>
</table>
</div>

<div style="top: 0; width: 100%; padding: 5px; padding-top: 25px;">
<input type="text" id="searchType" onkeyup="searchCards('Type')" placeholder="Search for type..">
<input type="text" id="searchOracle" onkeyup="searchCards('Oracle')" placeholder="Search for oracle..">
</div>

<div style="padding-top: 5px;">
<table id="collectionTable" style="width:100%">
<tbody>
<tr>
<th id="cardImage" scope="col">Image</th>
<th id="cardName" scope="col">Name</th>
<th id="cardType" scope="col">Type</th>
<th id="cardMana" scope="col">Mana Costs</th>
<th id="cardOracle" scope="col">Oracle</th>
<th id="cardChoice" scope="col">Choice</th>
<th id="cardCount" scope="col">Count</th>
</tr>
</tbody>
<tbody id="cardTBody">
</tbody>
</table>
</div>

@@ register.html.ep
% layout 'default';
% title 'Register';
<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            User Registration Form
        </div>
        <br /> <br />
        %= form_for register => (method => 'post') => begin
            <input class="form-control" 
                   id="username" 
                   name="username" 
                   type="username" size="56"
                   placeholder="Enter Username" 
             />
            <br /> <br />
            <input class="form-control" 
                   id="password" 
                   name="password" 
                   type="password" 
                   size="40" 
                   placeholder="Enter Password" 
             />   
            <br /> <br />
            <input class="form-control" 
                   id="confirm_password" 
                   name="confirm_password" 
                   type="password" 
                   size="40" 
                   placeholder="Confirm Password" 
             />   
            <br /> <br />
          %= submit_button 'Register' => (class => 'btn btn-primary')
            <br />  <br />
        % end
      % if ($error) {
            <div class="error" style="color: red">
                <small> <%= $error %> </small>
            </div>
        %}

        % if ($message) {
            <div class="error" style="color: green">
                <small> <%= $message %> </small>
            </div>
        %}
    </div>

</div>

@@ login.html.ep
% layout 'default';
% title 'Login';
<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            User Login Form
        </div>
        <br /> <br />
        %= form_for login => (method => 'post') => begin
            <input class="form-control" 
                   id="username" 
                   name="username" 
                   type="username" size="40"
                   placeholder="Enter Username" 
             />
            <br /> <br />
            <input class="form-control" 
                   id="password" 
                   name="password" 
                   type="password" 
                   size="40" 
                   placeholder="Enter Password" 
             />   
          %= submit_button 'Login' => (class => 'btn btn-primary')
            <br />  <br />
        % end
      % if ($error) {
            <div class="error" style="color: red">
                <small> <%= $error %> </small>
            </div>
        %}

        % if ($message) {
            <div class="error" style="color: green">
                <small> <%= $message %> </small>
            </div>
        %}
    </div>

</div>

@@ form.html.ep
% layout 'default';
% title 'Upload your Collection';
%= form_for upload => (enctype => 'multipart/form-data') => begin
  %= file_field 'collection'
  %= submit_button 'Upload'
% end

@@ progress_collection_import.html.ep
% layout 'default';
% title 'Progress of your Collection import';
<h1> 'Progress of your Collection import' <h1>
% if ($message) {
  <div class="error" style="color: green">
    <small> <%= $message %> </small>
  </div>
%}


@@ watch.html.ep
% layout 'default';
% title 'Listing';
<script>
var ws = new WebSocket('<%= url_for('watchws')->to_abs %>');
var msg = {"type":"database", "count":0, "data":null };
console.info(JSON.stringify(msg));

// Incoming messages
ws.onmessage = function (event) {
json = JSON.parse(event.data);

msg.type = json.type;
msg.count = json.count;
msg.data = null;
if ("database" == json.type) {
addRow(json.data);
ws.send(JSON.stringify(msg));
}
};

// Outgoing messages
ws.onopen = function (event) {
ws.send(JSON.stringify(msg));
};


function addRow(jsonContent)
{
  if (!document.getElementsByTagName) return;
  if (!document.getElementById) return;
  tabBody=document.getElementById("cardTBody");
  for (i = 0; i < jsonContent.length; i++) {
    row = document.createElement("tr");
    row.id = jsonContent[i].ID;
    cellImage = document.createElement("td");
    textImage = document.createElement("img");
    textImage.src='data:image/jpg;base64,'+jsonContent[i].Image;
    textImage.alt=jsonContent[i].Name;
    textImage.width="128";
    cellImage.appendChild(textImage);
    row.appendChild(cellImage);

    cellName = document.createElement("td");
    textName = document.createTextNode(jsonContent[i].Name);
    cellName.appendChild(textName);
    row.appendChild(cellName);

    cellType = document.createElement("td");
    textType = document.createTextNode(jsonContent[i].Type.replace(/Ã¢ÂÂ/g,'-'));
    cellType.appendChild(textType);
    row.appendChild(cellType);

    cellManaCost = document.createElement("td");
    textManaCost = document.createTextNode(jsonContent[i].ManaCost);
    cellManaCost.appendChild(textManaCost);
    row.appendChild(cellManaCost);

    cellOracle = document.createElement("td");
    textOracle = document.createTextNode(jsonContent[i].Oracle.replace(/Ã¢ÂÂ/g,'-').replace(/Ã¢ÂÂ¢/g,'"'));
    cellOracle.appendChild(textOracle);
    row.appendChild(cellOracle);

    tabBody.appendChild(row);
  }

};

const searchopt = {
  "Oracle" : 4,
  "ManaCost": 3,
  "Type": 2,
  "Name": 1
}

function search(key) {
  // Declare variables
  var input, filter, table, tr, td, i, txtValue;
  input = document.getElementById("search"+key);
  filter = input.value.toUpperCase();
  table = document.getElementById("collectionTable");
  tr = table.getElementsByTagName("tr");

  // Loop through all table rows, and hide those who don't match the search query
  for (i = 0; i < tr.length; i++) {
    td = tr[i].getElementsByTagName("td")[searchopt[key]];
    if (td) {
      txtValue = td.textContent || td.innerText;
      if (txtValue.toUpperCase().indexOf(filter) > -1) {
        tr[i].style.display = "";
      } else {
        tr[i].style.display = "none";
      }
    }
  }
};
</script>

<div style="position: fixed; top: 0; width: 100%; padding: 5px; margin-bottom: 25px;">
<input type="text" id="searchType" onkeyup="search('Type')" placeholder="Search for type..">
<input type="text" id="searchOracle" onkeyup="search('Oracle')" placeholder="Search for oracle..">
</div>
<div style="padding-top: 25px;">
<table id="collectionTable" style="width:100%">
<tr>
<th scope="col">Image</th>
<th scope="col">Name</th>
<th scope="col">Type</th>
<th scope="col">Mana Costs</th>
<th scope="col">Oracle</th>
</tr>
<tbody id="cardTBody">
</tbody>
</table>
</div>
