/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * A fixed-size worker pool for splitting one frame across cores.
 */

#pragma once

#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace libcamera {

/**
 * \brief Run one function over N bands of a frame and wait for all of them
 *
 * The software ISP runs entirely on one thread. On this hardware that thread
 * sits at 99.9% of a core while the other seven logical CPUs idle, and the
 * frame rate is simply 1000 / (milliseconds of work). Splitting the frame into
 * horizontal bands is the obvious remedy, and the pre-pass was already written
 * in row bands for an unrelated reason - setActiveRows() skips the rows the
 * debayer discards - so the shape was already there.
 *
 * Threads are created once and parked, not created per frame. At 30 fps a
 * per-frame std::thread costs its creation and teardown 120 times a second,
 * which on measurement here is a few milliseconds a frame - a meaningful
 * fraction of what the threading is trying to save.
 *
 * The caller runs band 0 itself rather than handing all bands to workers and
 * blocking. That keeps one fewer thread in the system, and more importantly it
 * means the single-threaded case costs exactly a function call: with no
 * workers, run() is a loop on the calling thread and no synchronisation
 * happens at all.
 *
 * run() returns only when every band is finished, so consecutive run() calls
 * are separated by a barrier. That is what lets the pre-pass thread its two
 * passes independently even though the second reads what the first wrote in
 * neighbouring bands.
 */
class ThreadPool
{
public:
	/**
	 * \param[in] threads Total bands to run in parallel, including the
	 * caller's own. 0 or 1 means no worker threads are created.
	 */
	explicit ThreadPool(unsigned int threads)
	{
		for (unsigned int i = 1; i < threads; i++)
			workers_.emplace_back([this, i] { worker(i); });
	}

	~ThreadPool()
	{
		{
			std::lock_guard<std::mutex> lock(mutex_);
			stop_ = true;
			generation_++;
		}
		start_.notify_all();
		for (auto &t : workers_)
			t.join();
	}

	ThreadPool(const ThreadPool &) = delete;
	ThreadPool &operator=(const ThreadPool &) = delete;

	/** \brief Bands this pool can run at once, counting the caller */
	unsigned int size() const { return workers_.size() + 1; }

	/**
	 * \brief Call \a fn(i) for i in [0, bands) and return once all have run
	 *
	 * \a bands must not exceed size(). Anything thrown by \a fn propagates
	 * on the calling thread only, so \a fn must not throw - the callers
	 * here are noexcept in practice.
	 */
	void run(unsigned int bands, const std::function<void(unsigned int)> &fn)
	{
		if (bands <= 1 || workers_.empty()) {
			for (unsigned int i = 0; i < bands; i++)
				fn(i);
			return;
		}

		if (bands > size())
			bands = size();

		{
			std::lock_guard<std::mutex> lock(mutex_);
			fn_ = &fn;
			bands_ = bands;
			pending_ = bands - 1;
			generation_++;
		}
		start_.notify_all();

		fn(0);

		std::unique_lock<std::mutex> lock(mutex_);
		done_.wait(lock, [this] { return pending_ == 0; });
	}

private:
	void worker(unsigned int index)
	{
		uint64_t seen = 0;
		for (;;) {
			const std::function<void(unsigned int)> *fn;
			unsigned int bands;
			{
				std::unique_lock<std::mutex> lock(mutex_);
				start_.wait(lock, [this, seen] {
					return stop_ || generation_ != seen;
				});
				if (stop_)
					return;
				seen = generation_;
				fn = fn_;
				bands = bands_;
			}

			/*
			 * Fewer bands than workers is legitimate - a short
			 * active band, or a caller asking for less - and those
			 * workers simply go back to waiting. They are not
			 * counted in pending_, so nothing waits on them.
			 */
			if (index >= bands)
				continue;

			(*fn)(index);

			std::lock_guard<std::mutex> lock(mutex_);
			if (--pending_ == 0)
				done_.notify_one();
		}
	}

	std::vector<std::thread> workers_;
	std::mutex mutex_;
	std::condition_variable start_;
	std::condition_variable done_;
	const std::function<void(unsigned int)> *fn_ = nullptr;
	uint64_t generation_ = 0;
	unsigned int bands_ = 0;
	unsigned int pending_ = 0;
	bool stop_ = false;
};

} /* namespace libcamera */
