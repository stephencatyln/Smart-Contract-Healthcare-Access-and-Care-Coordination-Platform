;; Appointment Scheduling Efficiency Contract
;; Reduces wait times and improves access to medical care

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-APPOINTMENT-EXISTS (err u201))
(define-constant ERR-APPOINTMENT-NOT-FOUND (err u202))
(define-constant ERR-INVALID-INPUT (err u203))
(define-constant ERR-SLOT-UNAVAILABLE (err u204))
(define-constant ERR-INVALID-STATUS (err u205))

;; Data Variables
(define-data-var next-appointment-id uint u1)
(define-data-var total-appointments uint u0)

;; Data Maps
(define-map appointments
  { appointment-id: uint }
  {
    patient: principal,
    provider-id: uint,
    appointment-time: uint,
    duration: uint,
    priority: uint,
    status: (string-ascii 20),
    notes: (string-ascii 500),
    created-at: uint
  }
)

(define-map provider-schedule
  { provider-id: uint, time-slot: uint }
  {
    available: bool,
    appointment-id: (optional uint),
    duration: uint
  }
)

(define-map patient-appointments
  { patient: principal }
  { appointment-ids: (list 50 uint) }
)

(define-map appointment-queue
  { priority: uint }
  { appointment-ids: (list 100 uint) }
)

(define-map wait-times
  { provider-id: uint }
  {
    average-wait: uint,
    total-appointments: uint,
    last-updated: uint
  }
)

;; Public Functions

;; Schedule a new appointment
(define-public (schedule-appointment (provider-id uint) (appointment-time uint) (duration uint) (priority uint) (notes (string-ascii 500)))
  (let
    (
      (appointment-id (var-get next-appointment-id))
      (caller tx-sender)
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (asserts! (> appointment-time current-time) ERR-INVALID-INPUT)
    (asserts! (and (>= priority u1) (<= priority u5)) ERR-INVALID-INPUT)
    (asserts! (> duration u0) ERR-INVALID-INPUT)

    ;; Check if time slot is available
    (asserts! (is-slot-available provider-id appointment-time duration) ERR-SLOT-UNAVAILABLE)

    ;; Create appointment
    (map-set appointments
      { appointment-id: appointment-id }
      {
        patient: caller,
        provider-id: provider-id,
        appointment-time: appointment-time,
        duration: duration,
        priority: priority,
        status: "scheduled",
        notes: notes,
        created-at: current-time
      }
    )

    ;; Reserve time slot
    (reserve-time-slot provider-id appointment-time duration appointment-id)

    ;; Add to patient appointments
    (add-to-patient-appointments caller appointment-id)

    ;; Add to priority queue
    (add-to-priority-queue priority appointment-id)

    ;; Update counters
    (var-set next-appointment-id (+ appointment-id u1))
    (var-set total-appointments (+ (var-get total-appointments) u1))

    (ok appointment-id)
  )
)

;; Update appointment status
(define-public (update-appointment-status (appointment-id uint) (status (string-ascii 20)))
  (let
    (
      (appointment-data (map-get? appointments { appointment-id: appointment-id }))
    )
    (asserts! (is-some appointment-data) ERR-APPOINTMENT-NOT-FOUND)

    (let
      (
        (appointment (unwrap-panic appointment-data))
        (caller tx-sender)
      )
      ;; Only patient or provider can update status
      (asserts! (or (is-eq caller (get patient appointment))
                   (is-authorized-provider caller (get provider-id appointment))) ERR-NOT-AUTHORIZED)

      (map-set appointments
        { appointment-id: appointment-id }
        (merge appointment { status: status })
      )

      ;; If cancelled, free up the time slot
      (if (is-eq status "cancelled")
        (free-time-slot (get provider-id appointment) (get appointment-time appointment) (get duration appointment))
        true
      )

      (ok true)
    )
  )
)

;; Reschedule appointment
(define-public (reschedule-appointment (appointment-id uint) (new-time uint) (new-duration uint))
  (let
    (
      (appointment-data (map-get? appointments { appointment-id: appointment-id }))
    )
    (asserts! (is-some appointment-data) ERR-APPOINTMENT-NOT-FOUND)

    (let
      (
        (appointment (unwrap-panic appointment-data))
        (caller tx-sender)
        (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      )
      (asserts! (is-eq caller (get patient appointment)) ERR-NOT-AUTHORIZED)
      (asserts! (> new-time current-time) ERR-INVALID-INPUT)
      (asserts! (is-slot-available (get provider-id appointment) new-time new-duration) ERR-SLOT-UNAVAILABLE)

      ;; Free old time slot
      (free-time-slot (get provider-id appointment) (get appointment-time appointment) (get duration appointment))

      ;; Reserve new time slot
      (reserve-time-slot (get provider-id appointment) new-time new-duration appointment-id)

      ;; Update appointment
      (map-set appointments
        { appointment-id: appointment-id }
        (merge appointment {
          appointment-time: new-time,
          duration: new-duration,
          status: "rescheduled"
        })
      )

      (ok true)
    )
  )
)

;; Complete appointment
(define-public (complete-appointment (appointment-id uint))
  (let
    (
      (appointment-data (map-get? appointments { appointment-id: appointment-id }))
    )
    (asserts! (is-some appointment-data) ERR-APPOINTMENT-NOT-FOUND)

    (let
      (
        (appointment (unwrap-panic appointment-data))
        (caller tx-sender)
      )
      (asserts! (is-authorized-provider caller (get provider-id appointment)) ERR-NOT-AUTHORIZED)

      ;; Update appointment status
      (map-set appointments
        { appointment-id: appointment-id }
        (merge appointment { status: "completed" })
      )

      ;; Update wait times
      (update-wait-times (get provider-id appointment))

      (ok true)
    )
  )
)

;; Set provider availability
(define-public (set-availability (provider-id uint) (time-slot uint) (duration uint) (available bool))
  (let
    (
      (caller tx-sender)
    )
    (asserts! (is-authorized-provider caller provider-id) ERR-NOT-AUTHORIZED)

    (map-set provider-schedule
      { provider-id: provider-id, time-slot: time-slot }
      {
        available: available,
        appointment-id: none,
        duration: duration
      }
    )
    (ok true)
  )
)

;; Private Functions

;; Check if time slot is available
(define-private (is-slot-available (provider-id uint) (appointment-time uint) (duration uint))
  (match (map-get? provider-schedule { provider-id: provider-id, time-slot: appointment-time })
    slot-data (and (get available slot-data) (is-none (get appointment-id slot-data)))
    true ;; If no schedule entry exists, assume available
  )
)

;; Reserve time slot
(define-private (reserve-time-slot (provider-id uint) (appointment-time uint) (duration uint) (appointment-id uint))
  (map-set provider-schedule
    { provider-id: provider-id, time-slot: appointment-time }
    {
      available: false,
      appointment-id: (some appointment-id),
      duration: duration
    }
  )
)

;; Free time slot
(define-private (free-time-slot (provider-id uint) (appointment-time uint) (duration uint))
  (map-set provider-schedule
    { provider-id: provider-id, time-slot: appointment-time }
    {
      available: true,
      appointment-id: none,
      duration: duration
    }
  )
)

;; Add appointment to patient's list
(define-private (add-to-patient-appointments (patient principal) (appointment-id uint))
  (let
    (
      (current-appointments (default-to { appointment-ids: (list) } (map-get? patient-appointments { patient: patient })))
    )
    (map-set patient-appointments
      { patient: patient }
      { appointment-ids: (unwrap-panic (as-max-len? (append (get appointment-ids current-appointments) appointment-id) u50)) }
    )
  )
)

;; Add to priority queue
(define-private (add-to-priority-queue (priority uint) (appointment-id uint))
  (let
    (
      (current-queue (default-to { appointment-ids: (list) } (map-get? appointment-queue { priority: priority })))
    )
    (map-set appointment-queue
      { priority: priority }
      { appointment-ids: (unwrap-panic (as-max-len? (append (get appointment-ids current-queue) appointment-id) u100)) }
    )
  )
)

;; Update wait times for provider
(define-private (update-wait-times (provider-id uint))
  (let
    (
      (current-stats (default-to { average-wait: u0, total-appointments: u0, last-updated: u0 }
                     (map-get? wait-times { provider-id: provider-id })))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (map-set wait-times
      { provider-id: provider-id }
      {
        average-wait: (get average-wait current-stats), ;; Would calculate based on actual wait times
        total-appointments: (+ (get total-appointments current-stats) u1),
        last-updated: current-time
      }
    )
  )
)

;; Check if caller is authorized provider
(define-private (is-authorized-provider (caller principal) (provider-id uint))
  ;; This would integrate with the provider network contract
  ;; For now, simplified check
  true
)

;; Read-only Functions

;; Get appointment details
(define-read-only (get-appointment (appointment-id uint))
  (map-get? appointments { appointment-id: appointment-id })
)

;; Get patient appointments
(define-read-only (get-patient-appointments (patient principal))
  (map-get? patient-appointments { patient: patient })
)

;; Get provider schedule
(define-read-only (get-provider-schedule (provider-id uint) (time-slot uint))
  (map-get? provider-schedule { provider-id: provider-id, time-slot: time-slot })
)

;; Get priority queue
(define-read-only (get-priority-queue (priority uint))
  (map-get? appointment-queue { priority: priority })
)

;; Get wait times
(define-read-only (get-wait-times (provider-id uint))
  (map-get? wait-times { provider-id: provider-id })
)

;; Get total appointments
(define-read-only (get-total-appointments)
  (var-get total-appointments)
)

;; Check availability for time range
(define-read-only (check-availability (provider-id uint) (start-time uint) (end-time uint))
  (and (> end-time start-time)
       (is-slot-available provider-id start-time (- end-time start-time)))
)
