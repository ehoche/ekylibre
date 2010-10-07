# = Informations
# 
# == License
# 
# Ekylibre - Simple ERP
# Copyright (C) 2009-2010 Brice Texier, Thibaud Mérigon
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see http://www.gnu.org/licenses.
# 
# == Table: sale_payments
#
#  account_number        :string(255)      
#  accounted_at          :datetime         
#  amount                :decimal(16, 2)   not null
#  bank                  :string(255)      
#  check_number          :string(255)      
#  commission_account_id :integer          
#  commission_amount     :decimal(16, 2)   default(0.0), not null
#  company_id            :integer          not null
#  created_at            :datetime         not null
#  created_on            :date             
#  creator_id            :integer          
#  deposit_id            :integer          
#  id                    :integer          not null, primary key
#  journal_entry_id      :integer          
#  lock_version          :integer          default(0), not null
#  mode_id               :integer          not null
#  number                :string(255)      
#  paid_on               :date             
#  parts_amount          :decimal(16, 2)   not null
#  payer_id              :integer          
#  receipt               :text             
#  received              :boolean          default(TRUE), not null
#  responsible_id        :integer          
#  scheduled             :boolean          not null
#  to_bank_on            :date             default(CURRENT_DATE), not null
#  updated_at            :datetime         not null
#  updater_id            :integer          
#

class SalePayment < ActiveRecord::Base
  acts_as_accountable
  attr_readonly :company_id
  belongs_to :commission_account, :class_name=>Account.name
  belongs_to :company
  belongs_to :responsible, :class_name=>User.name
  belongs_to :deposit
  belongs_to :journal_entry
  belongs_to :payer, :class_name=>Entity.name
  belongs_to :mode, :class_name=>SalePaymentMode.name
  has_many :parts, :class_name=>SalePaymentPart.name, :foreign_key=>:payment_id, :autosave=>true
  # has_many :orders, :through=>:parts, :source=>:expense, :source_type=>SaleOrder.name
  has_many :sale_orders, :through=>:parts, :source=>:expense, :source_type=>SaleOrder.name
  # has_many :purchase_orders, :through=>:parts, :source=>:expense, :source_type=>PurchaseOrder.name
  has_many :transfers, :through=>:parts, :source=>:expense, :source_type=>Transfer.name

  autosave :deposit

  attr_readonly :company_id, :payer_id
  attr_protected :parts_amount

  validates_numericality_of :amount, :greater_than=>0
  validates_numericality_of :parts_amount, :commission_amount, :greater_than_or_equal_to=>0
  validates_presence_of :to_bank_on, :payer, :created_on
  validates_presence_of :commission_account, :if=>Proc.new{|p| p.commission_amount!=0}
  
  def prepare_on_create
    self.created_on ||= Date.today
    self.to_bank_on ||= Date.today
    specific_numeration = self.company.preference("management.payments.numeration")
    if specific_numeration and specific_numeration.value
      self.number = specific_numeration.value.next_value
    else
      last = self.company.sale_payments.find(:first, :conditions=>["company_id=? AND number IS NOT NULL", self.company_id], :order=>"number desc")
      self.number = last ? last.number.succ : '000000'
    end
    self.scheduled = (self.to_bank_on>Date.today ? true : false) # if self.scheduled.nil?
    self.received = false if self.scheduled
    true
  end

  def prepare
    self.commission_account = self.mode.commission_account
    self.commission_amount = self.mode.commission_amount(self.amount)
    self.parts_amount = self.parts.sum(:amount)
  end

  def check
    errors.add(:amount, :greater_than_or_equal_to, :count=>self.parts_amount) if self.amount < self.parts_amount
  end
  
  def label
    tc(:label, :amount=>self.amount.to_s, :date=>self.created_at.to_date, :mode=>self.mode.name, :usable_amount=>self.unused_amount.to_s, :payer=>self.payer.full_name, :number=>self.number, :currency=>self.company.default_currency.symbol)
  end

  def unused_amount
    self.amount-self.parts_amount
  end

  def attorney_amount
    total = 0
    for part in self.parts
      total += part.amount if part.expense.client_id != part.payment.payer_id
    end    
    return total
  end

  # Use the minimum amount to pay the expense
  # If the payment is a downpayment, we look at the total unpaid amount
  def pay(expense, options={})
    raise Exception.new("Expense must be "+ SalePaymentPart.expense_types.collect{|x| "a "+x}.join(" or ")) unless SalePaymentPart.expense_types.include? expense.class.name
    downpayment = options[:downpayment]
    SalePaymentPart.destroy_all(:expense_type=>expense.class.name, :expense_id=>expense.id, :payment_id=>self.id)
    self.reload
    part_amount = [expense.unpaid_amount(!downpayment), self.unused_amount].min
    part = self.parts.create(:amount=>part_amount, :expense=>expense, :company_id=>self.company_id, :downpayment=>downpayment)
    if part.errors.size > 0
      errors.add_from_record(part)
      return false
    end
    return true
  end


  # This method permits to add journal entries corresponding to the payment
  # It depends on the preference which permit to activate the "automatic accountizing"
  def to_accountancy(action=:create, options={})
    attorney_amount = self.attorney_amount
    client_amount   = self.amount - attorney_amount
    mode = self.mode
    label = tc(:to_accountancy, :resource=>self.class.human_name, :number=>self.number, :payer=>self.payer.full_name, :mode=>mode.name, :expenses=>self.parts.collect{|p| p.expense.number}.to_sentence, :check_number=>self.check_number)
    accountize(action, {:journal=>mode.cash.journal, :printed_on=>self.to_bank_on, :draft_mode=>options[:draft]}, :unless=>(!mode.with_accounting? or !self.received)) do |entry|
      if mode.with_deposit?
        entry.add_debit(label, mode.depositables_account_id, self.amount)
      else
        entry.add_debit(label, mode.cash.account_id, self.amount-self.commission_amount)
        entry.add_debit(label, self.commission_account_id, self.commission_amount) if self.commission_amount > 0
      end
      entry.add_credit(label, self.payer.account(:client).id,   client_amount)   unless client_amount.zero?
      entry.add_credit(label, self.payer.account(:attorney).id, attorney_amount) unless attorney_amount.zero?
    end
  end
  
  def updatable?
    self.deposit.nil? or not self.deposit.locked
  end

end
