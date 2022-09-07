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
          print $key . ' ' . $table . " created successfully\n";
        }
      }
    }
  }
};

helper get_data => sub {
  my $c = shift;
  my $stmt = shift;

  my $sth = $c->dbh->prepare("$stmt");

  $sth->execute or die $DBI::errstr;
  if (defined $sth) {
    my $rows =  $sth->fetchall_hashref('ID');
    return $rows;
  }
  return undef;

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

helper create_user_collection => sub {
  my $c = shift;
  my $id = shift;
  my $stmt = "CREATE TABLE IF NOT EXISTS user_collection_$id (
    ID INTEGER NOT NULL UNIQUE,
    Count INTEGER NOT NULL,
    FOREIGN KEY (ID)
    REFERENCES mtg (ID) 
    ON DELETE CASCADE ON UPDATE NO ACTION
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
      deckName VARCHAR(255) NOT NULL,
      PRIMARY KEY (cardID, ID),
      FOREIGN KEY (cardID)
      REFERENCES mtg (ID) 
      ON DELETE CASCADE ON UPDATE NO ACTION
    );";
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


get '/' => sub ($c) {
  $c->render(template => 'index');
};

our $scrapeTimerID = Mojo::IOLoop->recurring(60 => sub ($loop) {
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
        my $rows = app->get_data('SELECT ID, Name FROM mtg WHERE Rawdata IS NULL LIMIT 10');
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
  my $res = $ua->max_redirects(2)->get("https://scryfall.com/search?q=$name")->result;
  print "fetched anchore child \n";
  my $toolboxLinks = $res->dom->find($xpath);

  # possible a grid
  unless (defined $toolboxLinks and $toolboxLinks->size) {
    print "find griditems\n";
    my $griditem = $res->dom->find('a[class=card-grid-item-card] > span[class="card-grid-item-invisible-label"]');
    foreach ($griditem->each) {
      $name =~ s/\+/ /;
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
  my $imageURL = undef;
  # test on Transform card
  if ( grep( /^Transform/, @{$json->{keywords}} ) ) {
    say "is Transform";
    foreach (@{$json->{card_faces}}) {
      $_->{oracle_text} =~ s/'/''/g;
      $type .= $_->{type_line};
      $oracle .= $_->{oracle_text};
      $oracle .= "\n";
      $type .= "\n";
      $imageURL = $_->{image_uris}->{small} unless (defined $imageURL);
    }
  } else {
    $json->{oracle_text} =~ s/'/''/g;
    $oracle = $json->{oracle_text};
    $type = $json->{type_line};
    $imageURL = $json->{image_uris}->{small};
  }

  print "fetching image \n";
  my $image = encode_base64($ua->max_redirects(2)->get($imageURL)->result->body or undef);
  
  if (defined $subproc) {
  print "update collection for $name\n";
  $subproc->progress({
      id => $id,
      oracle => $oracle,
      mana_cost => $json->{mana_cost},
      image => $image,
      type => $type,
      rawdata => encode_base64($jsonres->body)
    });
  } else {
    $c->update_scraped(
      $id,
      $oracle,
      $json->{mana_cost},
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
      $c->redirect_to('register');
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
    $c->flash(message => 'Thanks for logging in.');
    $c->redirect_to(
      "user/$user"
    );
  }
};

helper login_check => sub ($,$,$){
  my $c = shift;
  my $user = shift;
  my $pass = shift;
  my $res = $c->get_data("SELECT ID, Name, Password FROM Users WHERE Name = '$user'");
  my $id = $c->get_id($user, "users");
  my $pbkdf2 = Crypt::PBKDF2->new(
    hash_class => 'HMACSHA1', 
    iterations => 1000,       
    output_len => 20,         
    salt_len   => 4,         
  );
  return $pbkdf2->validate($res->{$id}->{Password},$pass) 
};

# Logout action
get '/logout' => sub ($c) {

  # Expire and in turn clear session automatically
  $c->session(expires => 1);

  # Redirect to main page with a 302 response
  $c->redirect_to('index');
};

group {
  under 'user/:user' => sub($c) {
    # Redirect to main page with a 302 response if user is not logged in
    return 1 if $c->session('user');
    $c->redirect_to('index');
    return undef;
  };
};


group {
  under 'collection';
  # Upload form in DATA section
  get '/upload' => 'form';

  # Multipart upload handler
  post '/upload' => sub ($c) {

    # Check file size
    return $c->render(text => 'File is too big.', status => 200) if $c->req->is_limit_exceeded;

    # Process uploaded file
    return $c->redirect_to('form') unless my $collection = $c->param('collection');

    import_collection($c, $collection) 
  };
};

sub import_collection {
  my $c = shift;
  my $collection = shift;


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
          $matrix->{$sum}[2] =~ s/'/''/;
          $matrix->{$sum}[3] =~ s/'/''/;
        } else {
          warn "Line could not be parsed: $line\n";
          $subproc->progress({ text => "Line could not be parsed: $line"})
        }
        # export to extra route
        if ($sum gt 0) {
          my $rv = $c->insert_collection(
            $matrix->{$sum}[2],
            $matrix->{$sum}[3],
            $matrix->{$sum}[13],
            $matrix->{$sum}[4]
          );
          print "insert number: $sum, ID: $rv\n";
          $subproc->progress({ text => "insert number: $sum, ID: $rv"})
        }
        $sum += 1;
      }
      return $matrix;
    })->then(sub ($matrix) {
      $c->render(json => $matrix);
    })->catch(sub ($err) {
      $c->render( text => $err )
    })->wait;

}

get '/watch' =>  sub($c) {
  $c->render(template => 'watch');
};

websocket '/watch/ws' =>  sub($c) {
  my $rows = $c->get_data('SELECT ID, Image, Name, Type, Oracle, ManaCost FROM mtg;');
  my $rows_size = keys %{$rows};


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
          count => $rmsg->{count}+10
        };
        my @part;
        foreach $_ ($rmsg->{count}+1 .. $rmsg->{count}+10) {
          push @part, { %{$rows->{$_}} } if defined $rows->{$_};
          if ($_ gt $rows_size) {
            $msg->{type => "databaseend"};
            last;
          };
        };

        $msg->{data} = [ @part ];
      };
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
%= button_to "Import Collection" => 'upload'  => (class => "")
%= button_to "Scrape" => '/scrape/scryfall'
%= button_to "Watch and search" => 'watch'
%= button_to "Register" => 'register'
%= button_to "Login" => 'login'


@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
<head>
<title><%= title %></title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
</head>
<body><%= content %></body>
</html>

@@ register.html.ep
% layout 'default';
% title 'Register';
<br /> <br />
<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            User Registration Form
        </div>
        <br /> <br />
        <form method="post" action='/register'>
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
            <br /> <br />
            <input class="form-control" 
                   id="confirm_password" 
                   name="confirm_password" 
                   type="password" 
                   size="40" 
                   placeholder="Confirm Password" 
             />   
            <br /> <br />
            <input class="btn btn-primary" type="submit" value="Register">
            <br />  <br />
        </form>
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
<br /> <br />
<div class="container">
    <div class="card col-sm-6 mx-auto">
        <div class="card-header text-center">
            User Login Form
        </div>
        <br /> <br />
        <form method="post" action='/login'>
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
            <input class="btn btn-primary" type="submit" value="Login">
            <br />  <br />
        </form>
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
  tabBody=document.getElementsByTagName("tbody").item(0);
  for (i = 0; i < jsonContent.length; i++) {
    row = document.createElement("tr");
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
    textType = document.createTextNode(jsonContent[i].Type);
    cellType.appendChild(textType);
    row.appendChild(cellType);

    cellManaCost = document.createElement("td");
    textManaCost = document.createTextNode(jsonContent[i].ManaCost);
    cellManaCost.appendChild(textManaCost);
    row.appendChild(cellManaCost);

    cellOracle = document.createElement("td");
    textOracle = document.createTextNode(jsonContent[i].Oracle);
    cellOracle.appendChild(textOracle);
    row.appendChild(cellOracle);

    tabBody.appendChild(row);
  }



};

function searchOracle() {
  // Declare variables
  var input, filter, table, tr, td, i, txtValue;
  input = document.getElementById("searchOracle");
  filter = input.value.toUpperCase();
  table = document.getElementById("collectionTable");
  tr = table.getElementsByTagName("tr");

  // Loop through all table rows, and hide those who don't match the search query
  for (i = 0; i < tr.length; i++) {
  td = tr[i].getElementsByTagName("td")[4];
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

function searchType() {
  // Declare variables
  var input, filter, table, tr, td, i, txtValue;
  input = document.getElementById("searchType");
  filter = input.value.toUpperCase();
  table = document.getElementById("collectionTable");
  tr = table.getElementsByTagName("tr");

  // Loop through all table rows, and hide those who don't match the search query
  for (i = 0; i < tr.length; i++) {
  td = tr[i].getElementsByTagName("td")[2];
  if (td) {
  txtValue = td.textContent || td.innerText;
  if (txtValue.toUpperCase().indexOf(filter) > -1) {
    tr[i].style.display = "";
  } else {
    tr[i].style.display = "none";
  }
}
  }
}
</script>

<div style="position: fixed; top: 0; width: 100%; padding: 5px; margin-bottom: 25px;">
<input type="text" id="searchType" onkeyup="searchType()" placeholder="Search for type..">
<input type="text" id="searchOracle" onkeyup="searchOracle()" placeholder="Search for oracle..">
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
<tbody>
</tbody>
</table>
</div>
