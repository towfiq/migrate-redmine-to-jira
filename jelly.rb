#!/usr/bin/env ruby

require 'rubygems'
require 'mysql2'
require 'builder'
require 'csv'

def log(str)
  puts "#{Time.now.strftime('%F %T')} #{str}"
end

PROJECT_KEYS = {
  'Puppet'               => 'PUPT',
  'Facter'               => 'FACT',
  'MCollective'          => 'MCOL',
  'Puppet Dashboard'     => 'DASH',
  'Puppet Documentation' => 'DOCS'
}

STATUS_TO_RESOLUTION = {
  'Closed'                        => 'Fixed',
  'Rejected'                      => 'Won\'t Fix',
  'Duplicate'                     => 'Duplicate',
  'Accepted'                      => nil,
  'Ready For Checkin'             => 'Fixed',
  'Unreviewed'                    => nil,
  'Needs Decision'                => 'Incomplete',
  'Needs More Information'        => 'Incomplete',
  'Re-opened'                     => nil,
  'In Topic Branch Pending Merge' => nil,
  'Code Insufficient'             => nil,
  'Tests Insufficient'            => nil,
  'Investigating'                 => nil,
  'Merged - Pending Release'      => 'Fixed',
  'Requires CLA to be signed'     => 'Require CLA'
}

STATUS_TO_STATUS = {
  'Closed'                        => 'Closed',
  'Rejected'                      => 'Closed',
  'Duplicate'                     => 'Closed',
  'Accepted'                      => 'Open',
  'Ready For Checkin'             => 'Resolved',
  'Unreviewed'                    => 'Open',
  'Needs Decision'                => 'Resolved',
  'Needs More Information'        => 'Resolved',
  'Re-opened'                     => 'Reopened',
  'In Topic Branch Pending Merge' => 'In Progress',
  'Code Insufficient'             => 'Reopened',
  'Tests Insufficient'            => 'Reopened',
  'Investigating'                 => 'In Progress',
  'Merged - Pending Release'      => 'Resolved',
  'Requires CLA to be signed'     => 'Resolved'
}

TRACKER_TO_TYPE = {
  'Bug'      => 'Bug',
  'Feature'  => 'New Feature',
  'Refactor' => 'Improvement'
}

PRIORITY_TO_PRIORITY = {
  'Low'       => 'Trivial',
  'Normal'    => 'Minor',
  'High'      => 'Major',
  'Urgent'    => 'Critical',
  'Immediate' => 'Blocker',
}

RELATION_TO_RELATION = {
  'blocks'     => 'blocks',
  'duplicates' => 'duplicates',
  'precedes'   => 'has to be done before',
  'relates'    => 'relates to'
}

JIRA_DATE_FORMAT = '%Y-%m-%d %h:%i %p'

PROJECTS_TO_EXPORT = [
  'Facter',
  'MCollective',
  'Puppet Dashboard',
  'Puppet Documentation',
  'Puppet'
]

dbh = Mysql2::Client.new(:host => "localhost", :username => "root", :database => "redmine")

log "Caching projects"
@projects = {}
dbh.query("SELECT id, name FROM projects WHERE projects.name IN (#{PROJECTS_TO_EXPORT.map {|p| "'#{p}'"}.join(', ')})").each do |project|
  @projects[project['id'].to_i] = project['name']
end

log "Caching issue statuses"
@statuses = {}
dbh.query('SELECT id, name FROM issue_statuses').each do |status|
  @statuses[status['id'].to_i] = status['name']
end

log "Caching issue types"
@issue_types = {}
dbh.query('SELECT id, name FROM trackers').each do |tracker|
  @issue_types[tracker['id'].to_i] = tracker['name']
end

log "Caching priorities"
@priorities = {}
dbh.query("SELECT id, name FROM enumerations WHERE type = 'IssuePriority'").each do |priority|
  @priorities[priority['id'].to_i] = priority['name']
end

log "Caching versions"
@versions = {}
dbh.query("SELECT id, name FROM versions").each do |version|
  @versions[version['id'].to_i] = version['name']
end

log "Caching users"
@users = {}
dbh.query("SELECT id, concat(firstname, ' ', lastname, ' (', login, ')') AS name FROM users").each do |user|
  @users[user['id'].to_i] = user['name']
end

def value_unknown_or_none(id_to_text, id)
  id = id.to_i

  return 'NONE' unless id

  id_to_text[id] || 'UNKNOWN'
end

def updated_from_to(prefix, old, new, id_to_text=nil)
  if id_to_text
    old_text = value_unknown_or_none(id_to_text, old)
    new_text = value_unknown_or_none(id_to_text, new)
  else
    old_text = old
    new_text = new
  end

  "#{prefix}: Updated from '#{old_text}' to '#{new_text}'\n"
end

def prop_update_string(prop, old, new, id)
  case prop
    when 'status_id'
      updated_from_to(
        "Status",
        old,
        new,
        @statuses
      )
    when 'assigned_to_id'
      updated_from_to(
        "Assigned to",
        old,
        new,
        @users
      )
    when 'fixed_version_id'
      updated_from_to(
        "Target version",
        old,
        new,
        @versions
      )
    when 'priority_id'
      updated_from_to(
        "Priority",
        old,
        new,
        @priorities
      )
    when 'subject'
      updated_from_to(
        "Subject",
        old,
        new
      )
    when 'project_id'
      updated_from_to(
        "Project",
        old,
        new,
        @projects
      )
    when 'due_date'
      updated_from_to(
        "Due Date",
        old,
        new
      )
    when 'start_date'
      updated_from_to(
        "Start Date",
        old,
        new
      )
    when 'tracker_id'
      updated_from_to(
        "Issue type",
        old,
        new,
        @issue_types
      )
    when 'parent_id'
      updated_from_to(
        "Parent issue",
        old,
        new
      )
    else
      raise Exception.new(
        "Unknown property '#{prop}' for journal detail entry: #{id}"
      )
  end
end

builder = Builder::XmlMarkup.new :indent => 2

builder.JiraJelly(:'xmlns:jira' => "jelly:com.atlassian.jira.jelly.JiraTagLib") do |j|
  ##
  ## TODO:
  ##   * Remove the WHERE clause when doing the final migration.
  ##   * :sendEmail => true
  ##
  log "Exporting users"
  dbh.query(
    'SELECT login, firstname, lastname, mail FROM users WHERE login = \'community\' ORDER BY id'
  ).each do |user|
    j.jira(
      :CreateUser,
      :username  => user['login'],
      :fullname  => "#{user['firstname']} #{user['lastname']}",
      :email     => user['mail'],
      :sendEmail => false
    )
  end

  dbh.query(
    "SELECT id, name, description, homepage FROM projects WHERE projects.name IN (#{PROJECTS_TO_EXPORT.map {|p| "'#{p}'"}.join(', ')})"
  ).each do |project|
    log "Exporting project: #{project['name']}"
    j.jira(
      :CreateProject,
      :key         => PROJECT_KEYS[project['name']],
      :name        => project['name'],
      :lead        => 'jhelwig',
      :url         => project['homepage'],
      :description => project['homepage']
    ) do |jp|

      dbh.query(
        "SELECT id, name, description, effective_date FROM versions WHERE project_id = #{project['id']}"
      ).each do |version|
        log "Adding version: #{version['name']}"
        jp.jira(
          :AddVersion,
          :name        => version['name'],
          :description => version['description'],
          :releaseDate => version['effective_date']
        )
      end

      issue_query = <<-SQL
        SELECT
          issues.id                                             AS id,
          issues.subject                                        AS summary,
          issues.description                                    AS description,
          affected_versions.value                               AS version,
          fixed_version.name                                    AS fix_version,
          trackers.name                                         AS tracker,
          DATE_FORMAT(issues.due_date,   '#{JIRA_DATE_FORMAT}') AS due_date,
          DATE_FORMAT(issues.created_on, '#{JIRA_DATE_FORMAT}') AS date_created,
          DATE_FORMAT(issues.updated_on, '#{JIRA_DATE_FORMAT}') AS date_modified,
          issue_statuses.name                                   AS status,
          assigned_users.login                                  AS asignee,
          author_users.login                                    AS reporter,
          issues.votes_value                                    AS votes,
          priority_enumerations.name                            AS priority
        FROM
          issues
          INNER JOIN projects
            ON (issues.project_id = projects.id)
          LEFT OUTER JOIN versions AS fixed_version
            ON (fixed_version.id = issues.fixed_version_id)
          LEFT OUTER JOIN
            (
              SELECT
                affected_custom_values.*
              FROM
                custom_values as affected_custom_values
                INNER JOIN custom_fields as affected_custom_fields
                 ON (affected_custom_fields.id = affected_custom_values.custom_field_id
                     AND affected_custom_fields.name IN ('Affected Puppet version', 'Affected Dashboard version', 'Affected mCollective version'))
              WHERE affected_custom_values.customized_type = 'Issue'
            ) AS affected_versions
            ON (issues.id = affected_versions.customized_id)
          INNER JOIN issue_statuses
            ON (issues.status_id = issue_statuses.id)
          INNER JOIN trackers
            ON (issues.tracker_id = trackers.id)
          LEFT OUTER JOIN users AS author_users
            ON (issues.author_id = author_users.id)
          LEFT OUTER JOIN users AS assigned_users
            ON (issues.assigned_to_id = assigned_users.id)
          LEFT OUTER JOIN enumerations AS priority_enumerations
            ON (priority_enumerations.id = issues.priority_id
                AND priority_enumerations.type = 'IssuePriority')
        WHERE
          issues.project_id = #{project['id']}
        ORDER BY
          id
      SQL

      dbh.query(issue_query).each do |issue|
        log "Exporting issue: #{issue['id']}"

        ##
        ## TODO:
        ##   * Remove before final migration.
        ##
        issue['assignee'] = 'community' unless issue['assignee'] == 'jhelwig'
        issue['reporter'] = 'community' unless issue['reporter'] == 'jhelwig'

        old_description = issue['description']
        issue['description'] = "Imported from Redmine issue ##{issue['id']}"
        issue['description'] << "\n\n#{old_description}" if old_description

        jp.jira(
          :CreateIssue,
          :issueType        => TRACKER_TO_TYPE[issue['tracker']],
          :summary          => issue['summary'],
          :priority         => PRIORITY_TO_PRIORITY[issue['priority']],
          :versions         => issue['version'],
          :fixVersions      => issue['fix_version'],
          :assignee         => issue['assignee'],
          :reporter         => issue['reporter'],
          :description      => issue['description'],
          :duedate          => issue['due_date'],
          :created          => issue['date_created'],
          :updated          => issue['date_modified'],
          :issueIdVar       => 'issue_id',
          :issueKeyVar      => "issue_key_#{issue['id']}",
          :duplicateSummary => 'ignore'
        )

        comment_query = <<-SQL
          SELECT
            journals.id                                             AS journal_id,
            users.login                                             AS user,
            DATE_FORMAT(journals.created_on, '#{JIRA_DATE_FORMAT}') AS created_on,
            notes                                                   AS content
          FROM
            journals
            LEFT OUTER JOIN users
              ON (journals.user_id = users.id)
          WHERE
            journalized_id = #{issue['id']}
          ORDER BY
            journals.created_on
        SQL

        dbh.query(comment_query).each do |comment|
          ##
          ## TODO:
          ##   * Remove before final migration
          ##
          comment['user'] = 'community' unless comment['user'] == 'jhelwig'

          detail_updates = dbh.query <<-SQL
            SELECT
              id,
              prop_key,
              old_value,
              value
            FROM
              journal_details
            WHERE
              journal_id = #{comment['journal_id'].to_i}
              AND property = 'attr'
            ORDER BY
              id
          SQL

          detail_text = nil
          detail_updates.each do |detail_update|
            next if %w(
              category_id
              done_ratio
              estimated_hours
              support_urls
            ).any? {|x| x ==  detail_update['prop_key']}

            detail_text ||= ""
            detail_text << prop_update_string(
              detail_update['prop_key'],
              detail_update['old_value'],
              detail_update['value'],
              detail_update['id']
            )
          end
          detail_text << "\n" if detail_text

          journal_text = ""
          journal_text << detail_text        if detail_text
          journal_text << comment['content'] if comment['content']

          jp.jira(
            :AddComment,
            :'issue-key' => "${issue_key_#{issue['id']}}",
            :commenter   => comment['user'],
            :comment     => journal_text,
            :created     => comment['created_on']
          )
        end
      end
    end
  end

  log "Linking issues"
  issue_relation_query = <<-SQL
    SELECT
      issue_from_id,
      issue_to_id,
      relation_type
    FROM
      issue_relations
    ORDER BY
      issue_from_id,
      issue_to_id,
      relation_type
  SQL
  dbh.query(issue_relation_query).each do |issue_relation|
    j.jira(
      :LinkIssue,
      :key => "issue_key_#{issue_relation['issue_from_id']}",
      :linkKey => "issue_key_#{issue_relation['issue_to_id']}",
      :linkDesc => RELATION_TO_RELATION[issue_relation['relation_type']]
    )
  end
end

jelly_file = 'redmine_dump.jelly'
log "Writing jelly file: #{jelly_file}"
File.open(jelly_file, 'w') do |f|
  f.puts builder.target!
end
log "All done!"
