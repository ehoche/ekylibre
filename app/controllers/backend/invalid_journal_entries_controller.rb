module Backend
  class InvalidJournalEntriesController < Backend::BaseController
    def index
      @current_page = 1
      @invalid_entries = JournalEntry.where.not(balance: 0.0).order(:printed_on)
      @invalid_entries_count = @invalid_entries.count
      @invalid_entries = @invalid_entries.page(@current_page).per(2)
    end

    # def move_page
    #   byebug
    #   @current_page = params[:page]
    #   @invalid_entries = JournalEntry.where.not(balance: 0.0).order(:printed_on)
    #   @invalid_entries_count = @invalid_entries.count
    #   @invalid_entries = @invalid_entries.page(params[:page]).per(2)
    # end

    def delete_all
      JournalEntry.where.not(balance: 0.0).destroy_all
      redirect_to controller: :journals, action: :index
    end
  end
end