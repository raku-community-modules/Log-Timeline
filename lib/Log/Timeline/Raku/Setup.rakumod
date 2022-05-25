use v6.d;
use Log::Timeline::Raku::LogTimelineSchema;

without %*ENV<RAKUDO_PRECOMP_WITH> {
    with %*ENV<LOG_TIMELINE_RAKU_EVENTS> {
        for .split(',') -> $event {
            given $event {
                when 'file' {
                    setup-file-logging();
                    CATCH {
                        default {
                            warn "Failed to set up file logging: $_";
                        }
                    }
                }
                when 'thread' {
                    setup-thread-logging();
                    CATCH {
                        default {
                            warn "Failed to set up thread logging: $_";
                        }
                    }
                }
                when 'socket' {
                    setup-async-socket-logging();
                    CATCH {
                        default {
                            warn "Failed to set up socket logging: $_";
                        }
                    }
                }
                default {
                    warn "Unsupported Log::Timeline Raku event '$event'";
                }
            }
        }
    }
}

sub setup-file-logging() {
    my $handle-lock = Lock.new;
    my Log::Timeline::Ongoing %handles{IO::Handle};

    IO::Handle.^lookup('open').wrap: -> IO::Handle $handle, |c {
        my \result = callsame;
        if result !~~ Failure {
            my $path = ~$handle.path;
            $handle-lock.protect: {
                %handles{$handle} = Log::Timeline::Raku::LogTimelineSchema::FileOpen.start(:$path);
            };
        }
        result
    };

    IO::Handle.^lookup('close').wrap: -> IO::Handle $handle, |c {
        my Log::Timeline::Ongoing $task = $handle-lock.protect: { %handles{$handle}:delete };
        $task.end if $task;
        callsame;
    }
}

sub setup-thread-logging() {
    my $thread-lock = Lock.new;
    my Log::Timeline::Ongoing %threads{Thread};

    Thread.^lookup('run').wrap(-> Thread $thread, |c {
        my \result = callsame;
        $thread-lock.protect: {
            %threads{$thread} = Log::Timeline::Raku::LogTimelineSchema::RunThread.start:
                    :id($thread.id), :name($thread.name);
        };
        result
    });

    Thread.^lookup('finish').wrap(-> Thread $thread, |c {
        my \result = callsame;
        my Log::Timeline::Ongoing $task = $thread-lock.protect: { %threads{$thread}:delete };
        $task.end if $task;
        result
    });

    Thread.start(-> {}).finish;
}

sub setup-async-socket-logging() {
    my $socket-lock = Lock.new;
    my Log::Timeline::Ongoing %sockets{IO::Socket::Async};

    IO::Socket::Async.^lookup('listen').wrap: -> $class, $host, $port, |c {
        my $task = Log::Timeline::Raku::LogTimelineSchema::AsyncSocketListen.start(:$host, :$port);
        my $listen = callsame();
        supply whenever $listen -> $socket {
            $socket-lock.protect: {
                %sockets{$socket} = Log::Timeline::Raku::LogTimelineSchema::AsyncSocketIncoming.start:
                        $task, :host($socket.peer-host), :port($socket.peer-port);
            }
            emit $socket;
            CLOSE $task.end;
        }
    }

    IO::Socket::Async.^lookup('connect').wrap: -> $class, $host, $port, |c {
        my $promise = callsame;
        my $socket-task = Log::Timeline::Raku::LogTimelineSchema::AsyncSocketConnect.start(:$host, :$port);
        my $establish-task = Log::Timeline::Raku::LogTimelineSchema::AsyncSocketEstablish.start($socket-task);
        $promise.then({
        $establish-task.end;
            if $promise.status == Kept {
                $socket-lock.protect: { %sockets{$promise.result} = $socket-task; }
            }
            else {
                $socket-task.end;
            }
        });
        $promise
    }

    IO::Socket::Async.^lookup('close').wrap: -> $socket, |c {
        my \result = callsame;
        my Log::Timeline::Ongoing $task = $socket-lock.protect: { %sockets{$socket}:delete };
        $task.end if $task;
        result
    }
}
