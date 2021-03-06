require 'spec_helper'
require 'async_cache/workers/sidekiq'

describe AsyncCache::Store do
  Store = AsyncCache::Store

  subject do
    Store.new(
      backend: Rails.cache,
      worker:  :sidekiq
    )
  end

  it "raises if it doesn't receive a worker class" do
    expect {
      Store.new backend: Rails.cache
    }.to raise_error(ArgumentError)
  end

  context 'caching' do
    def stub_not_present(key)
      expect(Rails.cache).to receive(:read).with(key).and_return(nil)
    end

    def stub_present(key, value)
      expect(Rails.cache).to receive(:read).with(key).and_return([value, 0])
    end

    before(:each) do
      Rails.cache.clear

      @key = 'a key'
    end

    it "synchronously calls #fetch if entry isn't present" do
      block     = proc { 'something' }
      cache_key = Store.base_cache_key @key, block.to_source

      stub_not_present cache_key

      version    = Time.now.to_i
      expires_in = 1.minute

      # Expect another synchronous call with a block to compute the value
      expect(Rails.cache).to receive(:write).with(cache_key, ['something', version], {:expires_in => expires_in}).and_call_original

      fetched_value = subject.fetch(@key, version, :expires_in => expires_in, &block)

      expect(fetched_value).to eql 'something'
    end

    it 'returns the stale value and enqueues the worker if entry is present and timestamp is changed' do
      block    = proc { |private_argument| private_argument * 2 }
      base_key = Store.base_cache_key @key, block.to_source

      # It will try to check that workers are present, so we need to make that
      # check be a no-op
      allow(subject.worker_klass).to receive(:has_workers?).and_return(true)

      old_value  = 'old!'
      timestamp  = Time.now
      expires_in = 10.days.to_i
      arguments  = [1]

      # Cache key is composed of *both* the key and the arguments given to the
      # block since those arguments determine the output of the block
      cache_key = ActiveSupport::Cache.expand_cache_key([base_key] + arguments)

      stub_present cache_key, 'old!'

      # Expecting it to call the worker with the block to compute the new value
      expect(subject.worker_klass).to receive(:enqueue_async_job).with(
        key:        cache_key,
        version:    timestamp.to_i,
        expires_in: expires_in,
        block:      anything,
        arguments:  arguments
      ) do |opts|
        block_source    = opts[:block]
        block_arguments = opts[:arguments]

        # Check the the block behaves correctly
        expect(eval(block_source).call(*block_arguments)).to eql 2
      end

      fetched_value = subject.fetch(@key, timestamp, :expires_in => expires_in, :arguments => arguments, &block)

      # Check that it immediately returns the stale value
      expect(fetched_value).to eql old_value
    end

    it "returns the current value if timestamp isn't changed" do
      block     = proc { 'bad!' }
      cache_key = Store.base_cache_key @key, block.to_source

      stub_present cache_key, 'value'

      timestamp = 0 # `stub_present` returns a timestamp of 0

      expect(subject.fetch(@key, timestamp, :expires_in => 1.minute, &block)).to eql 'value'
    end

  end # context caching

  describe '#determine_strategy' do
    it 'always generates when no data is cached' do
      # Combinations of needs-regen and synchronous-regen arguments
      combos = [
        [true, true],
        [true, false],
        [false, false],
        [false, true]
      ]

      combos.each do |(needs_regen, synchronous_regen)|
        expect(
          subject.determine_strategy(
            has_cached_data:   false,
            needs_regen:       needs_regen,
            synchronous_regen: synchronous_regen
          )
        ).to eql :generate
      end
    end

    context 'when needing regeneration' do
      let(:has_cached_data) { true }
      let(:needs_regen)     { true }

      it 'generates when told to synchronously-regenerate' do
        expect(
          subject.determine_strategy(
            has_cached_data:   has_cached_data,
            needs_regen:       needs_regen,
            synchronous_regen: true
          )
        ).to eql :generate
      end

      it 'enqueues when not told to synchronously-regenerate' do
        allow(subject.worker_klass).to receive(:has_workers?).and_return(true)

        expect(
          subject.determine_strategy(
            has_cached_data:   has_cached_data,
            needs_regen:       needs_regen,
            synchronous_regen: false
          )
        ).to eql :enqueue
      end

      it 'generates instead of enqueueing when workers are not available' do
        allow(subject.worker_klass).to receive(:has_workers?).and_return(false)

        expect(
          subject.determine_strategy(
            has_cached_data:   has_cached_data,
            needs_regen:       needs_regen,
            synchronous_regen: false
          )
        ).to eql :generate
      end
    end # context when needing regeneration

    it "returns current value if it doesn't need regeneration" do
      expect(
        subject.determine_strategy(
          has_cached_data:   true,
          needs_regen:       false,
          synchronous_regen: false
        )
      ).to eql :current
    end

  end # describe #determine_strategy

end
