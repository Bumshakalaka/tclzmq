#
# Broker peering simulation (part 2)
# Prototypes the request-reply flow
#

package require tclzmq

if {[llength $argv] < 2} {
    puts "Usage: peering2.tcl <main|client|worker> <self> <peer ...>"
    exit 1
}

set NBR_CLIENTS 10
set NBR_WORKERS 3
set LRU_READY   "READY" ; # Signals worker is ready

set peers [lassign $argv what self]
set tclsh [info nameofexecutable]
expr {srand([pid])}

switch -exact -- $what {
    client {
	# Request-reply client using REQ socket
	#
	tclzmq context context 1
	tclzmq socket client context REQ
	client connect "ipc://$self-localfe.ipc"

	while {1} {
	    # Send request, get reply
	    puts "Client: HELLO"
	    client s_send "HELLO"
	    set reply [client s_recv]
	    puts "Client: $reply"
	    after 1000
	}
	client close
	context term
    }
    worker {
	# Worker using REQ socket to do LRU routing
	#
	tclzmq context context 1
	tclzmq socket worker context REQ
	worker connect "ipc://$self-localbe.ipc"

	# Tell broker we're ready for work
	worker s_send $LRU_READY

	# Process messages as they arrive
	while {1} {
	    set msg [tclzmq zmsg_recv worker]
	    puts "Worker: [lindex $msg end]"
	    lset msg end "OK"
	    tclzmq zmsg_send worker $msg
	}

	worker close
	context term
    }
    main {
	puts "I: preparing broker at $self..."

	# Prepare our context and sockets
	tclzmq context context 1

	# Bind cloud frontend to endpoint
	tclzmq socket cloudfe context ROUTER
	cloudfe setsockopt IDENTITY $self
	cloudfe bind "ipc://$self-cloud.ipc"

	# Connect cloud backend to all peers
	tclzmq socket cloudbe context ROUTER
	cloudbe setsockopt IDENTITY $self

	foreach peer $peers {
	    puts "I: connecting to cloud frontend at '$peer'"
	    cloudbe connect "ipc://$peer-cloud.ipc"
	}

	# Prepare local frontend and backend
	tclzmq socket localfe context ROUTER
	localfe bind "ipc://$self-localfe.ipc"

	tclzmq socket localbe context ROUTER
	localbe bind "ipc://$self-localbe.ipc"

	# Get user to tell us when we can start…
	puts -nonewline "Press Enter when all brokers are started: "
	flush stdout
	gets stdin c

	# Start local workers
	for {set worker_nbr 0} {$worker_nbr < $NBR_WORKERS} {incr worker_nbr} {
	    puts "Starting worker $worker_nbr, output redirected to worker-$self-$worker_nbr.log"
	    exec $tclsh peering2.tcl worker $self {*}$peers > worker-$self-$worker_nbr.log 2>@1 &
	}

	# Start local clients
	for {set client_nbr 0} {$client_nbr < $NBR_CLIENTS} {incr client_nbr} {
	    puts "Starting client $client_nbr, output redirected to client-$self-$client_nbr.log"
	    exec $tclsh peering2.tcl client $self {*}$peers > client-$self-$client_nbr.log 2>@1 &
	}

	# Interesting part
	# -------------------------------------------------------------
	# Request-reply flow
	# - Poll backends and process local/cloud replies
	# - While worker available, route localfe to local or cloud

	# Queue of available workers
	set workers {}

	proc route_to_cloud_or_local {msg} {
	    global peers
	    # Route reply to cloud if it's addressed to a broker
	    foreach peer $peers {
		if {$peer eq [lindex $msg 0]} {
		    tclzmq zmsg_send cloudfe $msg
		    return
		}
	    }
	    # Route reply to client if we still need to
            tclzmq zmsg_send localfe $msg
	}

	proc handle_localbe {} {
	    global workers
	    # Handle reply from local worker
	    set msg [tclzmq zmsg_recv localbe]
	    set address [tclzmq zmsg_unwrap msg]
	    lappend workers $address
	    # If it's READY, don't route the message any further
	    if {[lindex $msg 0] ne "READY"} {
		route_to_cloud_or_local $msg
	    }
	}

	proc handle_cloudbe {} {
	    # Or handle reply from peer broker
	    set msg [tclzmq zmsg_recv cloudbe]
	    # We don't use peer broker address for anything
	    tclzmq zmsg_unwrap msg
	    route_to_cloud_or_local $msg
	}

	proc handle_client {s reroutable} {
	    global peers workers
	    if {[llength $workers]} {
		set msg [tclzmq zmsg_recv $s]
		# If reroutable, send to cloud 20% of the time
		# Here we'd normally use cloud status information
		#
		if {$reroutable && [llength $peers] && [expr {int(rand()*5)}] == 0} {
		    set peer [lindex $peers [expr {int(rand()*[llength $peers])}]]
		    set msg [tclzmq zmsg_push $msg $peer]
		    tclzmq zmsg_send cloudbe $msg
		} else {
		    set frame [lindex $workers 0]
		    set workers [lrange $workers 1 end]
		    set msg [tclzmq zmsg_wrap $msg $frame]
		    tclzmq zmsg_send localbe $msg
		}
	    }
	}

	proc handle_clients {} {
            # We'll do peer brokers first, to prevent starvation
	    if {"POLLIN" in [cloudfe getsockopt EVENTS]} {
		handle_client cloudfe 0
	    }
	    if {"POLLIN" in [localfe getsockopt EVENTS]} {
		handle_client localfe 1
	    }
	}

	localbe readable handle_localbe
	cloudbe readable handle_cloudbe
	localfe readable handle_clients
	cloudfe readable handle_clients

	vwait forever

	# When we're done, clean up properly
	localbe close
	localfe close
	cloudbe close
	cloudfe close
	context term
    }
}
