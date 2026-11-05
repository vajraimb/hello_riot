(** Networking layer Oasis is built on: Atacama (TCP acceptor pool),
    Nomad (HTTP/1.1 + WebSocket server) and Trail (middleware pipeline and
    router). *)

module Atacama = Atacama
module Trail = Trail
module Nomad = Nomad
