# Object representing core patient information and demographic data.
class Patient
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Userstamp
  include Mongoid::History::Trackable

  # The following are concerns, or groupings of domain-related methods
  # This blog post is a good intro: https://vaidehijoshi.github.io/blog/2015/10/13/stop-worrying-and-start-being-concerned-activesupport-concerns/
  include Urgency
  include Callable
  include Notetakeable
  include PatientSearchable
  include AttributeDisplayable
  include LastMenstrualPeriodMeasureable
  include Pledgeable
  include HistoryTrackable
  include Statusable
  include Exportable
  include EventLoggable
  extend Enumerize

  LINES.each do |line|
    scope line.downcase.to_sym, -> { where(:line.in => [line]) }
  end

  before_validation :clean_fields
  before_save :save_identifier
  before_update :update_pledge_sent_by_sent_at
  before_update :update_fund_pledged_at
  after_create :initialize_fulfillment
  after_update :confirm_still_urgent, if: :urgent_flag?

  # Relationships
  has_and_belongs_to_many :users, inverse_of: :patients
  belongs_to :clinic
  embeds_one :fulfillment
  embeds_many :calls
  embeds_many :external_pledges
  embeds_many :notes
  belongs_to :pledge_generated_by, class_name: 'User', inverse_of: nil
  belongs_to :pledge_sent_by, class_name: 'User', inverse_of: nil
  belongs_to :last_edited_by, class_name: 'User', inverse_of: nil

  # Enable mass posting in forms
  accepts_nested_attributes_for :fulfillment

  # Fields
  # Searchable info
  field :name, type: String # strip
  field :primary_phone, type: String
  field :other_contact, type: String
  field :other_phone, type: String
  field :other_contact_relationship, type: String
  field :identifier, type: String

  # Contact-related info
  field :voicemail_preference
  enumerize :voicemail_preference, in: [:not_specified, :no, :yes], default: :not_specified

  field :line
  enumerize :line, in: LINES, default: LINES[0] # See config/initializers/env_vars.rb

  field :language, type: String
  field :initial_call_date, type: Date
  field :urgent_flag, type: Boolean
  field :last_menstrual_period_weeks, type: Integer
  field :last_menstrual_period_days, type: Integer

  # Program analysis related or NAF eligibility related info
  field :age, type: Integer
  field :city, type: String
  field :state, type: String
  field :county, type: String
  field :race_ethnicity, type: String
  field :employment_status, type: String
  field :household_size_children, type: Integer
  field :household_size_adults, type: Integer
  field :insurance, type: String
  field :income, type: String
  field :special_circumstances, type: Array, default: []
  field :referred_by, type: String
  field :referred_to_clinic, type: Boolean

  # Status and pledge related fields
  field :appointment_date, type: Date
  field :procedure_cost, type: Integer
  field :patient_contribution, type: Integer
  field :naf_pledge, type: Integer
  field :fund_pledge, type: Integer
  field :fund_pledged_at, type: Time
  field :pledge_sent, type: Boolean
  field :resolved_without_fund, type: Boolean
  field :pledge_generated_at, type: Time
  field :pledge_sent_at, type: Time

  # Indices
  index({ primary_phone: 1 }, unique: true)
  index(other_contact_phone: 1)
  index(name: 1)
  index(other_contact: 1)
  index(urgent_flag: 1)
  index(line: 1)
  index(identifier: 1)

  # Validations
  validates :name,
            :primary_phone,
            :initial_call_date,
            :created_by_id,
            :line,
            presence: true
  validates :primary_phone, format: /\d{10}/,
                            length: { is: 10 },
                            uniqueness: true
  validates :other_phone, format: /\d{10}/,
                          length: { is: 10 },
                          allow_blank: true
  validates :appointment_date, format: /\A\d{4}-\d{1,2}-\d{1,2}\z/,
                               allow_blank: true

  validate :confirm_appointment_after_initial_call

  validate :pledge_sent, :pledge_info_presence, if: :updating_pledge_sent?

  validates_associated :fulfillment

  # History and auditing
  track_history on: fields.keys + [:updated_by_id],
                version_field: :version,
                track_create: true,
                track_update: true,
                track_destroy: true
  mongoid_userstamp user_model: 'User'

  # Methods
  def self.pledged_status_summary(lines = LINES)
    # return pledge totals for patients with appts in the next num_days
    # outstanding_pledges = 0
    # sent_total = 0
    start_of_week = Time.zone.today.beginning_of_week(:monday)
    end_of_week = Time.zone.today.end_of_week(:monday)
    patients = Patient.in(line: lines)
                      .between(appointment_date: start_of_week..end_of_week)
                      .where(:fund_pledge.nin => ['', nil])
                      .map(&:to_simplified_patient)

    patients.reduce do |acc = { sent: [], pledged: [] }, patient|
      if patient.pledge_sent?
        acc[:sent] << patient
      else
        acc[:pledged] << patient
      end
      acc
    end
  end

  def to_simplified_patient
    {
      fund_pledge: patient.fund_pledge,
      pledge_sent: patient.pledge_sent?,
      id: patient.id,
      name: patient.name,
      identifier: patient.identifier,
      appointment_date: patient.appointment_date,
      fund_pledged_at: patient.fund_pledged_at
    }
  end

  def save_identifier
    self.identifier = "#{line[0]}#{primary_phone[-5]}-#{primary_phone[-4..-1]}"
  end

  def event_params
    {
      event_type:    'Pledged',
      cm_name:       updated_by&.name || 'System',
      patient_name:  name,
      patient_id:    id,
      line:          line,
      pledge_amount: fund_pledge
    }
  end

  private

  def confirm_appointment_after_initial_call
    if appointment_date.present? && initial_call_date > appointment_date
      errors.add(:appointment_date, 'must be after date of initial call')
    end
  end

  def clean_fields
    primary_phone.gsub!(/\D/, '') if primary_phone
    other_phone.gsub!(/\D/, '') if other_phone
    name.strip! if name
    other_contact.strip! if other_contact
    other_contact_relationship.strip! if other_contact_relationship
  end

  def initialize_fulfillment
    build_fulfillment(created_by_id: created_by_id).save
  end

  def update_pledge_sent_by_sent_at
    if pledge_sent && !pledge_sent_by
      self.pledge_sent_at = Time.zone.now
      self.pledge_sent_by = last_edited_by
    elsif !pledge_sent
      self.pledge_sent_by = nil
      self.pledge_sent_at = nil
    end
  end

  def update_fund_pledged_at
    if fund_pledge && !fund_pledged_at
      fund_pledged_at = Time.zone.now
    elsif fund_pledge.blank?
      fund_pledged_at = nil
    end
  end
end
