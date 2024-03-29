package Mojolicious::Plugin::Slackbot;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Loader;
use Mojo::Redis2;

has namespace => join '::', __PACKAGE__;
has params => sub { [qw/token team_id channel_id channel_name timestamp user_id user_name trigger_word/] };
has bots => sub { {} };

sub register {
  my ($self, $app) = @_;

  $app->plugin(Minion => {File => 'minion.db'});
  $app->helper(redis => sub { shift->stash->{redis} ||= Mojo::Redis2->new });
  $app->helper(job_timer => sub {
    my ($c, $task, $timer) = @_;
    $c->redis->rpush("$task:queue_time", time() - $timer);
  });

  my @bots = ();
  my @failed_bots = ();
  my $l = Mojo::Loader->new;
  foreach my $module ( @{$l->search($self->namespace)} ) {
    my ($plugin) = ($module =~ /::(\w+)$/);
    next unless $plugin eq lc($plugin);
    if ( $l->load($module) ) {
      push @{$self->bots->{failed}}, $plugin;
      $app->log->error("Error loading Slackbot plugin $plugin");
    } else {
      push @{$self->bots->{loaded}}, $plugin;
      $module->can('add_tasks') and $module->new(c=>shift)->add_tasks($plugin => $app);
      $app->helper("slackbot.$plugin" => sub { $module->new(c=>shift) });
    }
  }

  $app->routes->post('/slackbot' => sub {
    my $c = shift;

    warn Data::Dumper::Dumper({map { $_ => $c->param($_) } $c->param}) if $app->mode eq 'development';
    return $c->render(status => 401, text => '') unless $app->mode eq 'development' || ($c->param('token') && $c->param('token') eq $c->config->{slackbot}->{token});
    return $c->render(status => 204, text => '') if $c->param('user_name') && ($c->param('user_name') eq $c->config->{slackbot}->{name} || $c->param('user_name') eq 'slackbot');

    $c->render_later;    
    my $bots = {};
    $c->app->log->debug(sprintf 'Checking "%s" from %s#%s for triggers...', $c->param('text')||'', $c->param('user_name')||'', $c->param('channel_name')||'');
    foreach my $bot ( @{$self->bots->{loaded}} ) {
      $c->app->log->debug(sprintf '  %s', $bot);
      next unless my $trigger_word = $c->slackbot->$bot->triggered;
      $c->app->log->debug(sprintf 'Rendering responses using "%s"', $bot);
      my $tasks = $c->minion->tasks;
      foreach my $task ( grep { /^$bot:/ } keys %$tasks ) {
        $c->app->log->debug(sprintf "[%s] Queueing %s in %s to %s", $task, ($trigger_word?'response':'auto-response'), $c->param('channel_name')||'', $c->param('user_name')||'');
        push @{$bots->{tasks}->{$bot}}, [$task => $c->minion->enqueue($task => [$c->param('channel_name')||'', $c->param('user_name')||'', $c->param('text')||''])];
      }
      $bots->{responses}->{$bot} = [grep { $_ } @{$c->slackbot->$bot->render->responses}];
    }
    
    if ( my @tasks = grep { $_ } map { @{$bots->{tasks}->{$_}} } keys %{$bots->{tasks}} ) {
      $c->app->log->debug(sprintf "Queued %s jobs from %s bots now", $#tasks+1, scalar keys %{$bots->{tasks}});
    }
    if ( my @responses = grep { $_ } map { join "\n", @{$bots->{responses}->{$_}} } keys %{$bots->{responses}} ) {
      $c->app->log->debug(sprintf "Rendering %s responses from %s bots now", $#responses+1, scalar keys %{$bots->{responses}});
      return $c->render(json => {text => join "\n", @responses});
    }

    if ( keys %{$bots->{tasks}} ) {
      $c->app->log->debug('No direct response from any bot, but you might get some after the jobs are finished');
      $c->render(status => 202, text => '');
    } else {
      $c->app->log->debug('No responses from any bots, nor any queued up');
      $c->render(status => 204, text => '');
    }
  });
}

1;
