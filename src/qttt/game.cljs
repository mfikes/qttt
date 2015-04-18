(ns qttt.game
  "Logic relating to game state"
  (:require [clojure.set :as set]))

(def num-cells 9)
(def num-players 2)

(def ^:dynamic *speculative* false)

;; TODO: make cycles of size 2 work (approach: become aware of the turn they were played on)
;; TODO: make hover highlighting work (approach: third top-level activity)
;; TODO: make cycle collapse work

(comment
  ;; Game Data Structures

  ;; Game
  {:turn   0
   :player 0
   :pair [4 2]
   :board board
   :base game
   }

  ;; The board
  {0 cell 1 cell}

   ;; A cell
  {:entanglements {0 {:player 0
                      :turn 0
                      :pair 1
                      :focus false
                      :collapsing true}
                   1 {:player 1
                      :pair 2
                      :turn 1
                      :focus true}}
   :classical {:player 0
               :turn 0
               :speculative true}})

(defn next-player
  [player]
  (mod (inc player) num-players))

(defn get-entanglements
  "Return information regarding cells entangled with the given cell.

   Return value is a seq of [cell turn] tuples, where turn
   is the turn the spooky mark was placed. Also exclude
   entanglements which have a classical value already."

  [game cell]
  (->> (get-in game [:board cell :entanglements])
    (vals)
    (keep (fn [e] (when (and (:pair e)
                         (not (get-in game [:board (:pair e) :classical])))
                   [(:pair e) (:turn e)])))))

(defn index-of
  "Return the index of an item in a vector, if present. If not present return nil"
  [v item]
  (first (keep-indexed (fn [i val]
                         (when (= val item) i))
           v)))

(defn cycle-search
  "Return a seq of cell cycles discovered"
  [game cell visited from-turn]
  (set (mapcat (fn [[edge turn]]
                 (when-not (= turn from-turn)
                   (if-let [idx (index-of visited edge)]
                     [(set (conj (subvec visited idx) cell))]
                     (cycle-search game edge (conj visited cell) turn))))
         (get-entanglements game cell))))

(defn detect-cycles
  "Return a sequence of all entanglement cycles present in the given board"
  [game]
  ;; Not 100% efficient, but we need some way of detecting multiple disjoint graphs.
  ;; Should be fine for small N. Using sets removes redundancies. If we run into perf
  ;; trouble we can track which nodes we've visited *at all* and never revisit them.
  (apply set/union (map #(cycle-search game % [] -1) (keys (:board game)))))

(defn check-collapses
  "Given a game, check if there are any collapses happening
   and return an updated game accordingly"
  [game]
  (let [cycles (detect-cycles game)]
    (if (empty? cycles)
      (assoc game :collapsing false)
      (let [collapsing-cells (apply set/union cycles)]
        (reduce (fn [g cell]
                  (let [collapsing-subcells
                        (keep
                          (fn [[sub e]] (when (contains? collapsing-cells (:pair e)) sub))
                          (get-in g [:board cell :entanglements]))]
                    (reduce #(assoc-in %1 [:board cell :entanglements %2 :collapsing] true) g collapsing-subcells)))
          (assoc game :collapsing true)
          collapsing-cells)))))

(defn legal-spooky-mark?
  "Return true if a spooky mark can be placed on the given cell and subcell"
  [game cell subcell]
  (and
    (not= cell (first (:pair game)))
    (nil? (get-in game [:board cell :entanglements subcell]))))

(defn entangle
  "Given a cell, a subcell and the entangled cell and subcell, create an entanglement"
  [game cell subcell pair-cell pair-subcell]
  (if-not (legal-spooky-mark? game cell subcell)
    game
    (-> game
      ;; add the new spooky mark
      (assoc-in [:board cell :entanglements subcell]
        {:player (:player game)
         :turn (:turn game)
         :pair pair-cell
         :focus *speculative*})
      ;; update the entangled spooky mark
      (update-in [:board pair-cell :entanglements pair-subcell] assoc
        :focus *speculative*
        :pair cell)
      ;; remove the pair tracker
      (dissoc :pair)
      ;; change the player
      (update-in [:player] next-player)
      ;; update the turn
      (update-in [:turn] inc)
      ;; check for collapses
      (check-collapses))))

(defn resolve-collapse
  "Given a cell and subcell, resolve any collapse present in the game"
  [game cell subcell]
  (println "resolving collapse")
  game)

(defn spooky-mark
  "Place a spooky mark at the given cell and subcell"
  [game cell subcell]
  (if-let [[pair-cell pair-subcell] (:pair game)]
    (entangle game cell subcell pair-cell pair-subcell)
    (if-not (legal-spooky-mark? game cell subcell)
      game
      (-> game
        (assoc :pair [cell subcell])
        (assoc-in  [:board cell :entanglements subcell]
          {:player (:player game)
           :turn (:turn game)
           :focus true})))))

(defn play
  "Play an action at the given cell and subcell.
   What the action is depends on the game context."
  [game cell subcell]
  (if (:collapsing game)
    (resolve-collapse game cell subcell)
    (spooky-mark game cell subcell)))

(defn speculate
  "Make a play, but store the previous game state so the 'play' can be easily reverted"
  [game cell subcell]
  (binding [*speculative* true]
    (-> game
      (play cell subcell)
      (assoc :base game))))

(defn unspeculate
  "Restore the previous game state (if there was one)."
  [game]
  (if (:base game) (:base game) game))

(def new-game
  {:turn 0
   :player 0
   :board (zipmap (range num-cells)
                  (repeat {:entanglements {}}))})

