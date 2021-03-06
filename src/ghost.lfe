(defmodule ghost
 ; GHOST: Generalized Hierarchical Object STorage
 (export all))

;;;--------------------------------------------------------------------
;;; Keys
;;;--------------------------------------------------------------------
(defsyntax key-ghost-object
 ([object-id] (: eru er_key 'ghost 'id object-id)))

(defsyntax key-user-vote
 ([user-id type] (: eru er_key 'ghost 'vote 'user user-id type)))

(defsyntax key-user-vote-up
 ([user-id] (key-user-vote user-id 'up)))

(defsyntax key-user-vote-down
 ([user-id] (key-user-vote user-id 'down)))

(defsyntax key-object-vote
 ([parent-id child-id type]
  (: eru er_key 'ghost 'vote 'object parent-id child-id type)))

(defsyntax key-object-vote-updown
 ([parent-id child-id type]
  (: eru er_key 'ghost 'vote 'updown parent-id child-id type)))

(defsyntax key-object-vote-up
 ([parent-id child-id] (key-object-vote parent-id child-id 'up)))

(defsyntax key-object-vote-down
 ([parent-id child-id] (key-object-vote parent-id child-id 'down)))

(defsyntax key-children-of-object
 ([parent-id] (: eru er_key 'ghost 'children parent-id)))

(defsyntax key-renamed-child-by-parent
 ([parent-id] (: eru er_key 'ghost 'renamed parent-id)))

;(defsyntax key-vote-object-total
; ([child-id] (: eru er_key 'ghost 'vote 'total child-id)))

(defsyntax key-data
 ([in-data] (: eru er_key 'ghost 'data
             (: mochihex to_hex (: crypto sha in-data)))))

(defsyntax key-parents-of-object
 ([child-id] (: eru er_key 'ghost 'parents-of child-id)))

 (defsyntax key-child-count-of-parent
  ([parent-id] (: eru er_key 'ghost 'cc parent-id)))

;;;--------------------------------------------------------------------
;;; Object Creation
;;;--------------------------------------------------------------------
(defun object_create (redis object-id data-ptr)
 (object_create redis object-id data-ptr data-ptr))

(defun object_create (redis object-id data-ptr data-contents)
 ; we don't allow duplicate object ids, but we do allow the same data
 ; to point to multiple ids.
 ; Allowing the data pointer to be different than data contents means we
 ; can have the same essential content (say, the text of an article) in multiple
 ; objects, but the data pointer itself has metadata to the contents.
 ; Example: five people post the same essay or file.  It's the same data,
 ;          but our data-ptr will probably point to information about the
 ;          individual post (username, timestamp, etc).  Indexing by
 ;          unique metadata isn't useful, but indexing by the actual
 ;          contents of the post/file could be beneficial.
 (case (: er setnx redis (key-ghost-object object-id) data-ptr)
         ; this sadd is the inverse DATA->{Set of Keys Using Data} map
  ('true (: er sadd redis (key-data data-contents) object-id))
  ('false (tuple 'error 'object_id_already_exists object-id))))

(defun object_parent (redis parent-id child-id)
 ; for all parents of this child (including this here-parent) increase
 ; their has-a-child count.  We're doing full depth child counts, people.
 ; need to maintain a list of child-id -> [parent-ids]
 ; for each parent id in list, increase the child count.
 (add-parent redis child-id parent-id) ; parents are unranked
 ; NOTE: if a child has many many many parents, this will take a few seconds:
 ; (this would be a great candidate for redis scripting)
 ; IF YOU ADD A CHILD TO A PARENT AND THE CHILD HAS SUB-CHILDREN, THEY WILL NOT
 ; BE REFLECTED IN THE TOTAL COUNT.  increment-parent-child only does +1
 (increment-parent-child-count redis child-id) ; fully recursive up the chain
 (object_weight_update redis parent-id child-id 0))

;;;--------------------------------------------------------------------
;;; Object Updating
;;;--------------------------------------------------------------------
(defun add-parent (redis child-id parent-id)
 (: er sadd redis (key-parents-of-object child-id) parent-id))

(defun remove-parent (redis child-id parent-id)
 (: er srem redis (key-parents-of-object child-id) parent-id))

(defun increment-parent-child-count (redis child-id)
 (increment-child-count redis (parents-of-child redis child-id) '()))

(defun increment-child-count
 ([redis () anti-loop-log] anti-loop-log)
 ([redis (parent . parents) anti-loop-log]
  (case (: lists member parent anti-loop-log)
   ('true ; already visisted this parent, skip it and continue
    (increment-child-count redis parents anti-loop-log))
   ('false
    (let ((new-anti-looper (cons parent anti-loop-log)))
     (: er incrby redis (key-child-count-of-parent parent) 1)
     (increment-child-count redis
      (parents-of-child redis parent) new-anti-looper) ; avoid loops
     (increment-child-count redis parents new-anti-looper))))))

(defun object_weight_update (redis parent-id child-id delta)
 (: er zincrby redis (key-children-of-object parent-id) delta
  (latest-id redis parent-id child-id)))

(defun object_remove_from_parent (redis parent-id child-id)
 (remove-parent redis child-id parent-id)
 ; this decrby will keep decrby-ing even if the other two operations
 ; are noops.  we should only decrby if the child is successfully
 ; removed from the parent.
 (: er decrby redis (key-child-count-of-parent parent-id) 1)
 (: er zrem redis (key-children-of-object parent-id) child-id))

(defun object_rename (redis parent-id old-child-id new-child-id)
 ; this is completely non-transactional.  we may be dropping votes here
 ; if someone votes between our get-and-set
 (let ((current-weight (vote_total redis parent-id old-child-id)))
  ; This historical parent->child  relation should be stored as metadata
  ; in the new object so we can backtrack to find the old state of the
  ; system
  ; Remove the old comment before adding the new comment so we don't
  ; show both by mistake.
  ; This may cause some lookups between this very short period of time
  ; to have this entire child comment tree abasent until the weight_update
  ; below takes hold.

  ; log that {parent, old-child-id} -> {parent, new-child-id} so we can
  ; fix any incoming comments with old ID parings
  (: er hset redis
   (key-renamed-child-by-parent parent-id) old-child-id new-child-id)
  (: er zrem redis (key-children-of-object parent-id) old-child-id)
  ; my stupid er library throws an error because redis returns an error
  ; when the object's (key-children-of-object) key doesn't exist.
  ; just catch-to-ignore it here
  ; these *really* should be transactional
  (catch (: er rename redis
   (key-children-of-object old-child-id)
   (key-children-of-object new-child-id)))
  (catch (: er rename redis
   (key-object-vote-updown parent-id old-child-id 'up)
   (key-object-vote-updown parent-id new-child-id 'up)))
  (catch (: er rename redis
   (key-object-vote-updown parent-id old-child-id 'down)
   (key-object-vote-updown parent-id new-child-id 'down)))
  (object_weight_update redis parent-id new-child-id current-weight)
  current-weight))

(defun find-one-more-recent-id (redis parent-id child-id)
 (case (: er hget redis (key-renamed-child-by-parent parent-id) child-id)
  ('nil 'latest)
  (newer-child-id newer-child-id)))

(defun latest-id (redis parent-id child-id)
 (find-latest-id redis parent-id child-id '()))

(defun find-latest-id (redis parent-id child-id anti-loop-log)
 ; if we've visited this child-id, just assume it's the latest.  we're looping.
 (case (: lists member child-id anti-loop-log)
  ('true child-id)
  ('false
   ; else, traverse the old->new log until we reach the latest entry
   (case (find-one-more-recent-id redis parent-id child-id)
    ('latest child-id)
    (newer-child-id
     (find-latest-id redis parent-id newer-child-id
      (cons child-id anti-loop-log)))))))

;;;--------------------------------------------------------------------
;;; Object Reading
;;;--------------------------------------------------------------------
(defun parents-of-child (redis child-id)
 (: er smembers redis (key-parents-of-object child-id)))

(defun number-of-children (redis parent-id)
 (case (: er get redis (key-child-count-of-parent parent-id))
  ('nil 0)
  (N (list_to_integer (binary_to_list N)))))

(defun object_top_n_children (redis object-id n)
 (: er zrevrange redis
  (key-children-of-object object-id) 0 (- n 1) 'withscores))

(defun object_children (redis object-id)
 (object_top_n_children redis object-id 0)) ; this zero gets turned into -1
                                            ; and -1 means "the last entry"

(defun object_resolve_to_height (redis object-id height)
 (object_resolve_to_depth redis object-id height 65535)) ; assume 64k = 'inf

(defun object_resolve_to_depth
 ([redis object-id height 0] '())
 ([redis object-id height 1] ; this is a shortcut so we don't recurse as much.
                             ; it's the same as the next function clause
                             ; since we give recur-child-depth a 0 depth
  (lc ((<- (tuple child score) (object_top_n_children redis object-id height)))
   (tuple child score '())))
 ([redis object-id height depth]
  (lc ((<- (tuple child score) (object_top_n_children redis object-id height)))
   (tuple child score
    (recur-child-depth redis
     (- depth 1) child (object_children redis child))))))

(defun recur-child-depth (redis depth parent-id child-ids-with-scores)
 (recur-child-depth redis depth child-ids-with-scores (list parent-id) '()))

(defun recur-child-depth
 ([redis 0 _ seen result] (: lists reverse result))
 ([redis _ '() seen result] (: lists reverse result))
 ([redis depth ((tuple child-id child-score) . xs) seen result]
  (cond
   ((: lists member child-id seen) ; change to better type if performance prob
     (recur-child-depth redis depth xs seen ; already in seen, no adding again
      (cons (tuple child-id child-score 'cycle) result)))
   ('true
    (let ((new-seen (cons child-id seen)))
     (recur-child-depth redis depth xs new-seen
      (cons (tuple child-id child-score
             (recur-child-depth redis
              (- depth 1) (object_children redis child-id)
              new-seen '()))
       result)))))))

;;;--------------------------------------------------------------------
;;; Vote Casting
;;;--------------------------------------------------------------------
(defun vote (redis diff parent-id child-id user-id)
 (vote redis diff 1 parent-id child-id user-id))

(defun vote (redis diff weight parent-id child-id user-id)
 (let* (((list delta type) (case diff
                            ('up   (list (* +1 weight) 'up))
                            ('down (list (* -1 weight) 'down))))
        (new-score (object_weight_update redis parent-id child-id delta))
        (latest-id (latest-id redis parent-id child-id)))
  ; this incrby is so we can look up scores purely by child-id and not with
  ; a required (parent-id, child-id) combination
  ; but, we don't appear to be using it anywhere.  let's comment it out:
  ; (: er incrby redis (key-vote-object-total child-id) delta)
  (: er sadd redis (key-object-vote parent-id latest-id type) user-id)
  (: er sadd redis (key-user-vote user-id type)
                   (: eru er_key parent-id latest-id))
  ; here we record the number of up/down vote totals for this {parent, child}
  (: er incrby redis (key-object-vote-updown parent-id latest-id type) 1)
  (: er publish redis (: eru er_key 'ghost 'votes 'user user-id) type)
  (: er publish redis (: eru er_key 'ghost 'votes 'object parent-id latest-id)
   type)
  (: er publish redis (: eru er_key 'ghost 'votes 'object latest-id) type)
  new-score))

;;;--------------------------------------------------------------------
;;; Vote Reading
;;;--------------------------------------------------------------------
(defun vote_total_object (redis child-id)
 (: er get redis child-id))

(defun vote_total (redis parent-id child-id)
 (: er zscore redis (key-children-of-object parent-id) child-id))

(defun votes_by_object (redis parent-id child-id)
 (tuple
  (: er smembers redis (key-object-vote-up parent-id child-id))
  (: er smembers redis (key-object-vote-down parent-id child-id))))

(defun votes_updown (redis parent-id child-id)
 (tuple
  (: er get redis (key-object-vote-updown parent-id child-id 'up))
  (: er get redis (key-object-vote-updown parent-id child-id 'down))))

(defun votes_by_user (redis user-id)
 (tuple
  (: er smembers redis (key-user-vote-up user-id))
  (: er smembers redis (key-user-vote-down user-id))))
