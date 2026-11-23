module Harness
  class Error < StandardError; end
  class CommandError < Error; end

  class VerificationError < Error
    attr_reader :category, :exit_code, :output

    def initialize(message, category:, exit_code:, output:)
      super(message)
      @category = category
      @exit_code = exit_code
      @output = output
    end
  end

  class ReviewError < Error
    attr_reader :review

    def initialize(message, review:)
      super(message)
      @review = review
    end
  end

  class QaError < Error
    attr_reader :report

    def initialize(message, report: nil)
      super(message)
      @report = report
    end
  end
end
