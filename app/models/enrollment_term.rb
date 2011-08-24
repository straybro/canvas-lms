#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class EnrollmentTerm < ActiveRecord::Base
  DEFAULT_TERM_NAME = "Default Term"
  
  include Workflow

  attr_accessible :name, :start_at, :end_at, :ignore_term_date_restrictions
  belongs_to :root_account, :class_name => 'Account'
  has_many :enrollment_dates_overrides
  has_many :courses
  has_many :enrollments, :through => :courses
  has_many :course_sections
  before_validation :verify_unique_sis_source_id
  validates_length_of :sis_data, :maximum => maximum_text_length, :allow_nil => true, :allow_blank => true
  before_save :update_enrollments_later

  def update_enrollments_later
    self.send_later_if_production(:touch_all_enrollments) if !self.new_record? && self.start_at_changed? || self.end_at_changed?
  end

  def touch_all_enrollments
    return if new_record?
    case Enrollment.connection.adapter_name
    when 'MySQL'
      Enrollment.connection.execute("UPDATE users, enrollments, courses SET users.updated_at=NOW(), enrollments.updated_at=NOW() WHERE users.id=enrollments.user_id AND enrollments.course_id=courses.id AND courses.enrollment_term_id=#{self.id}")
    else
      Enrollment.update_all({:updated_at => Time.now}, "course_id IN (SELECT id FROM courses WHERE enrollment_term_id=#{self.id})")
      User.update_all({:updated_at => Time.now}, "id IN (SELECT user_id FROM enrollments INNER JOIN courses ON enrollments.course_id=courses.id WHERE courses.enrollment_term_id=#{self.id})")
    end
  end
  
  def self.i18n_default_term_name
    t '#account.default_term_name', "Default Term"
  end
  
  def default_term?
    read_attribute(:name) == EnrollmentTerm::DEFAULT_TERM_NAME
  end
  
  def name
    if default_term?
      EnrollmentTerm.i18n_default_term_name
    else
      read_attribute(:name)
    end
  end
  
  def name=(new_name)
    if new_name == EnrollmentTerm.i18n_default_term_name
      write_attribute(:name, DEFAULT_TERM_NAME)
    else
      write_attribute(:name, new_name)
    end
  end
  
  def set_overrides(context, params)
    return unless params && context
    params.map do |type, values|
      type = type.classify
      enrollment_type = Enrollment.typed_enrollment(type).to_s
      override = self.enrollment_dates_overrides.find_or_create_by_enrollment_type(enrollment_type)
      override.start_at = values[:start_at]
      override.end_at = values[:end_at]
      override.context = context
      override.save
      override
    end
  end
  
  def verify_unique_sis_source_id
    return true unless self.sis_source_id
    existing_term = self.root_account.enrollment_terms.find_by_sis_source_id(self.sis_source_id)
    return true if !existing_term || existing_term.id == self.id 
    
    self.errors.add(:sis_source_id, t('errors.not_unique', "SIS ID \"%{sis_source_id}\" is already in use", :sis_source_id => self.sis_source_id))
    false
  end
  
  def users_count
    Enrollment.active.count(
      :select => "enrollments.user_id", 
      :distinct => true,
      :joins => :course,
      :conditions => ['enrollments.course_id = courses.id AND courses.enrollment_term_id = ?', id]
    )
  end
  
  workflow do
    state :active
    state :deleted
  end
  
  def enrollment_dates_for(enrollment)
    return [nil, nil] if ignore_term_date_restrictions
    override = EnrollmentDatesOverride.find_by_enrollment_term_id_and_enrollment_type(self.id, enrollment.type.to_s)
    if override
      [override.start_at, override.end_at]
    else
      [start_at, end_at]
    end
  end
  
  alias_method :destroy!, :destroy
  def destroy
    self.workflow_state = 'deleted'
    save!
  end
  
  named_scope :active, lambda {
    { :conditions => ['enrollment_terms.workflow_state != ?', 'deleted'] }
  }
end
